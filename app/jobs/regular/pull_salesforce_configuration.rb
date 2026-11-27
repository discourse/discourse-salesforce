# frozen_string_literal: true

module Jobs
  class PullSalesforceConfiguration < ::Jobs::Base
    sidekiq_options retry: 5

    OVERLAP = 5.minutes

    def execute(args)
      configuration =
        ::DiscourseCrm::SyncConfiguration.active.inbound.find_by(
          id: args[:configuration_id],
          provider: "salesforce",
        )
      return unless configuration&.reason_enabled?(args[:reason])
      # A cursor belongs to the CRM account it was read from.
      return if args[:account] && args[:account] != configuration.account

      started_at = args[:started_at] ? Time.zone.parse(args[:started_at]) : Time.zone.now
      since = args[:after] ? args[:since] : window(configuration, args[:reason])
      import = ::Salesforce::RecordImport.new(configuration)
      batch = import.fetch_page(since: since, after: args[:after])
      records = batch.records
      history_result = args[:history_result]
      import.import_page(records) do |page|
        reasons = page.reasons(summarize_unchanged: args[:reason] == "scheduled")
        configuration.record_import_results(
          reasons,
          scheduled_at: started_at.iso8601,
          errors: page.destination_errors,
        )
        if reasons.any?
          history_result = "recorded"
        elsif records.any?
          history_result ||= "no_matching_users"
        end
      end

      if batch.last
        configuration.finish_pull(started_at, history_result)
      else
        cursor = import.cursor(records)
        # A cursor that does not move would request the same page forever.
        if cursor == args[:after]
          raise ::Salesforce::InvalidApiResponse.new("Salesforce pull cursor did not advance")
        end
        Jobs.enqueue(
          self.class,
          configuration_id: configuration.id,
          account: configuration.account,
          reason: args[:reason],
          started_at: started_at.iso8601,
          since: since&.to_s,
          after: cursor,
          history_result: history_result,
        )
      end
    rescue ::DiscourseCrm::RecordImport::Paused
      nil
    rescue => error
      configuration&.record_result(error: error)
      raise unless ::Salesforce::InboundUsersFlow.stops_pull?(error)
      Rails.logger.warn(
        "Salesforce pull stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
      )
    end

    private

    def window(configuration, reason)
      return if reason == "backfill" || configuration.last_synced_at.nil?
      (configuration.last_synced_at - OVERLAP).iso8601
    end
  end
end
