# frozen_string_literal: true

module Jobs
  class SyncSalesforceUserBatch < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      Salesforce::ConfiguredUserBatchSync.sync(
        args[:configuration_id],
        args[:user_ids],
        reason: args[:reason],
      )
      Salesforce::SyncConfiguration.record_batch_success(args[:configuration_id])
    rescue => error
      Salesforce::SyncConfiguration.record_result(args[:configuration_id], error: error)
      unless error.is_a?(Discourse::InvalidParameters) ||
               error.is_a?(Salesforce::AmbiguousEmailMatch)
        raise
      end
      Rails.logger.warn(
        "Salesforce configured batch stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
      )
    end
  end
end
