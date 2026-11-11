# frozen_string_literal: true

module Jobs
  class SyncHubspotConfiguration < ::Jobs::Base
    sidekiq_options retry: 5

    SEARCH_CURSOR_LIMIT = 10_000
    OVERLAP = 5.minutes
    RATE_LIMIT_DELAY = 60

    def execute(args)
      configuration = Salesforce::SyncConfiguration.active.find_by(id: args[:configuration_id])
      return unless configuration&.reason_enabled?(args[:reason])

      started_at = args[:started_at] ? Time.zone.parse(args[:started_at]) : Time.zone.now
      import = Hubspot::ContactImport.new(configuration)
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
      import.import_page(results)

      next_after = page.dig("paging", "next", "after")
      next_args = {
        configuration_id: configuration.id,
        reason: args[:reason],
        started_at: started_at.iso8601,
      }
      if next_after.blank?
        Salesforce::SyncConfiguration
          .where(id: configuration.id)
          .where("last_synced_at IS NULL OR last_synced_at < ?", started_at)
          .update_all(last_synced_at: started_at, last_error: nil, last_error_at: nil)
      elsif since && next_after.to_i >= SEARCH_CURSOR_LIMIT
        restart = restart_window(results, since)
        Jobs.enqueue(:sync_hubspot_configuration, **next_args, since: restart.iso8601)
      else
        Jobs.enqueue(
          :sync_hubspot_configuration,
          **next_args.merge(after: next_after, since: since&.iso8601).compact,
        )
      end
    rescue Hubspot::RateLimited => error
      Jobs.enqueue_in(
        error.retry_after || RATE_LIMIT_DELAY,
        :sync_hubspot_configuration,
        args.to_h.symbolize_keys,
      )
    rescue => error
      Salesforce::SyncConfiguration.record_result(args[:configuration_id], error: error)
      raise unless error.is_a?(Discourse::InvalidParameters)
      Rails.logger.warn(
        "HubSpot import stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
      )
    end

    private

    def import_api
      @import_api ||= Hubspot::Api.new
    end

    def search_window(configuration, args)
      return if args[:reason] == "backfill"
      return Time.zone.parse(args[:since]) if args[:since]
      return if args[:after]
      configuration.last_synced_at && configuration.last_synced_at - OVERLAP
    end

    def restart_window(results, since)
      value = results.last&.dig("properties", Hubspot::Api::LAST_MODIFIED_PROPERTY)
      restart = value.present? ? Time.zone.parse(value) : nil
      if restart.nil? || restart <= since
        raise Hubspot::InvalidApiResponse.new(
                "Search reached #{SEARCH_CURSOR_LIMIT} results without a later modified date",
              )
      end
      restart
    end
  end
end
