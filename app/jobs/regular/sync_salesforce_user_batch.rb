# frozen_string_literal: true

module Jobs
  class SyncSalesforceUserBatch < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      configuration =
        ::DiscourseCrm::SyncConfiguration.active.outbound.find_by(
          id: args[:configuration_id],
          provider: "salesforce",
        )
      return unless configuration
      pending_user_ids = Array(args[:user_ids]).map(&:to_i).uniq
      Salesforce::ConfiguredUserBatchSync.sync(
        args[:configuration_id],
        args[:user_ids],
        reason: args[:reason],
      ) { |user_id| pending_user_ids.delete(user_id) }
      ::DiscourseCrm::SyncConfiguration.record_batch_success(args[:configuration_id])
    rescue => error
      ::DiscourseCrm::SyncConfiguration.record_batch_failure(
        args[:configuration_id],
        pending_user_ids || args[:user_ids],
        error: error,
      )
      unless error.is_a?(Discourse::InvalidParameters) ||
               error.is_a?(Salesforce::AmbiguousEmailMatch)
        raise
      end
      Rails.logger.warn(
        "CRM configured batch stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
      )
    end
  end
end
