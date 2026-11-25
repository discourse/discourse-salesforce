# frozen_string_literal: true

module Jobs
  module Hubspot
    class SyncConfiguration < ::Jobs::Base
      sidekiq_options retry: 5

      SEARCH_CURSOR_LIMIT = 10_000
      OVERLAP = 5.minutes

      def execute(args)
        configuration =
          ::DiscourseCrm::SyncConfiguration.active.inbound.find_by(
            id: args[:configuration_id],
            provider: "hubspot",
          )
        return unless configuration&.reason_enabled?(args[:reason])

        started_at = args[:started_at] ? Time.zone.parse(args[:started_at]) : Time.zone.now
        import = ::Hubspot::ContactImport.new(configuration, api: import_api)
        next_args = {
          configuration_id: configuration.id,
          reason: args[:reason],
          started_at: started_at.iso8601,
        }
        next_args[:history_result] = args[:history_result] if args[:history_result]
        if args[:companies_after]
          return refresh_companies(configuration, import, args, next_args, started_at)
        end
        since = search_window(configuration, args)
        page =
          if since
            import_api.search_contacts_modified_since(
              since,
              after: args[:after],
              properties: import.requested_properties,
            )
          else
            import_api.list_contacts(after: args[:after], properties: import.requested_properties)
          end
        results = page.fetch("results")
        company_phase = args[:reason] == "scheduled" && import.pulls_companies?
        reasons =
          import.import_page(results, defer_companies: company_phase) do |imported_page|
            imported = imported_page.reasons(summarize_unchanged: args[:reason] == "scheduled")
            configuration.record_import_results(imported, scheduled_at: next_args[:started_at])
            imported
          end
        if reasons.any?
          next_args[:history_result] = "recorded"
        elsif results.any?
          next_args[:history_result] ||= "no_matching_users"
        end

        next_after = page.dig("paging", "next", "after")
        if next_after.blank?
          if company_phase
            Jobs.enqueue(::Jobs::Hubspot::SyncConfiguration, **next_args, companies_after: "")
          else
            finish(configuration, started_at, next_args[:history_result])
          end
        elsif since && next_after.to_i >= SEARCH_CURSOR_LIMIT
          restart = restart_window(results, since)
          Jobs.enqueue(::Jobs::Hubspot::SyncConfiguration, **next_args, since: restart.iso8601)
        else
          Jobs.enqueue(
            ::Jobs::Hubspot::SyncConfiguration,
            **next_args.merge(after: next_after, since: since&.iso8601).compact,
          )
        end
      rescue ::Hubspot::RateLimited => error
        ::Hubspot::SyncActivity.record_failure(configuration, nil, error)
        Jobs.enqueue_in(
          error.retry_after,
          ::Jobs::Hubspot::SyncConfiguration,
          args.to_h.symbolize_keys,
        )
      rescue => error
        configuration&.record_result(error: error)
        unless error.is_a?(Discourse::InvalidParameters) ||
                 error.is_a?(::Hubspot::DailyQuotaExceeded)
          raise
        end
        Rails.logger.warn(
          "HubSpot import stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
        )
      end

      private

      def import_api
        @import_api ||= ::Hubspot::Api.new
      end

      def refresh_companies(configuration, import, args, next_args, started_at)
        ids = import.referenced_company_ids(after: args[:companies_after])
        return finish(configuration, started_at, next_args[:history_result]) if ids.empty?

        import.refresh_companies(ids, allow_partial_import: true) do |result|
          if result.nil? ||
               ::Hubspot::SyncActivity.record_company_results(
                 configuration,
                 ids,
                 result,
                 started_at,
               )
            next_args[:history_result] = "recorded"
          end
        end
        Jobs.enqueue(::Jobs::Hubspot::SyncConfiguration, **next_args, companies_after: ids.last)
      end

      def finish(configuration, started_at, history_result)
        ::DiscourseCrm::SyncAttempt.transaction do
          unless history_result == "recorded"
            ::DiscourseCrm::SyncAttempt.record(
              configuration,
              nil,
              reason: history_result || "no_contacts",
            )
          end
          ::DiscourseCrm::SyncConfiguration
            .where(id: configuration.id)
            .where("last_synced_at IS NULL OR last_synced_at < ?", started_at)
            .update_all(last_synced_at: started_at, last_error: nil, last_error_at: nil)
        end
        return unless SiteSetting.crm_segments_enabled
        Jobs.enqueue(
          ::Jobs::DiscourseCrm::EvaluateSegments,
          provider: configuration.provider,
          account: configuration.account,
        )
      end

      def search_window(configuration, args)
        return if args[:reason] == "backfill"
        return Time.zone.parse(args[:since]) if args[:since]
        return if args[:after]
        configuration.last_synced_at && configuration.last_synced_at - OVERLAP
      end

      def restart_window(results, since)
        value = results.last&.dig("properties", ::Hubspot::Api::LAST_MODIFIED_PROPERTY)
        restart = value.present? ? Time.zone.parse(value) : nil
        if restart.nil? || restart <= since
          raise ::Hubspot::InvalidApiResponse.new(
                  "Contact search limit reached without a later modified date",
                )
        end
        restart
      end
    end
  end
end
