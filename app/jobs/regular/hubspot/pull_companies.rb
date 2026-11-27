# frozen_string_literal: true

module Jobs
  module Hubspot
    class PullCompanies < ::Jobs::Base
      sidekiq_options retry: 5

      def execute(args)
        configuration =
          ::DiscourseCrm::SyncConfiguration.active.inbound.find_by(
            id: args[:configuration_id],
            provider: "hubspot",
            object: "company",
          )
        return unless configuration&.reason_enabled?(args[:reason])
        # A cursor belongs to the CRM account it was read from.
        return if args[:account] && args[:account] != configuration.account

        started_at = args[:started_at] ? Time.zone.parse(args[:started_at]) : Time.zone.now
        import = ::Hubspot::CompanyImport.new(configuration)
        # A user's contact pull asks only for that user's companies, and reports only to them.
        if args[:company_ids]
          ids = args[:company_ids]
          refresh(configuration, import, ids, started_at, user_id: args[:user_id])
          # Every user whose contact points to these companies sees the change.
          user_ids = import.linked_contacts(ids).distinct.pluck("crm_record_links.user_id")
          configuration.evaluate_segments_later(user_ids:) if user_ids.any?
          return
        end

        ids = import.referenced_ids(after: args[:after].to_s)
        history_result = args[:history_result]
        if ids.empty?
          import.remove_unreferenced
          return(
            configuration.finish_pull(started_at, history_result, empty_reason: "no_companies")
          )
        end

        history_result = "recorded" if refresh(configuration, import, ids, started_at)
        Jobs.enqueue(
          self.class,
          configuration_id: configuration.id,
          account: configuration.account,
          reason: args[:reason],
          started_at: started_at.iso8601,
          after: ids.last,
          history_result: history_result,
        )
      rescue ::DiscourseCrm::RecordImport::Paused
        nil
      rescue ::Hubspot::RateLimited => error
        ::Hubspot::SyncActivity.record_failure(configuration, nil, error)
        Jobs.enqueue_in(error.retry_after, self.class, args.to_h.symbolize_keys)
      rescue => error
        configuration&.record_result(error: error)
        unless error.is_a?(Discourse::InvalidParameters) ||
                 error.is_a?(::Hubspot::DailyQuotaExceeded)
          raise
        end
        Rails.logger.warn(
          "HubSpot company pull stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
        )
      end

      private

      # True when the refresh left activity history.
      def refresh(configuration, import, ids, started_at, user_id: nil)
        import.refresh(ids) do |result|
          result.nil? ||
            ::Hubspot::SyncActivity.record_company_results(
              configuration,
              import.linked_contacts(ids, user_id:),
              result,
              started_at,
            )
        end
      end
    end
  end
end
