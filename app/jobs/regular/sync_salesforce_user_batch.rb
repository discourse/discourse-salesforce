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
      Salesforce::GuidedSyncConfiguration.record_batch_success(args[:configuration_id])
    rescue => error
      Salesforce::GuidedSyncConfiguration.record_result(args[:configuration_id], error: error)
      raise
    end
  end
end
