# frozen_string_literal: true

module Jobs
  class SyncSalesforceUserBatch < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      configuration = DiscourseCrm::SyncConfiguration.active.find_by(id: args[:configuration_id])
      return unless configuration
      if configuration.provider == "hubspot"
        return unless sync_hubspot_users(configuration, args)
      else
        Salesforce::ConfiguredUserBatchSync.sync(
          args[:configuration_id],
          args[:user_ids],
          reason: args[:reason],
        )
      end
      DiscourseCrm::SyncConfiguration.record_batch_success(args[:configuration_id])
    rescue => error
      DiscourseCrm::SyncConfiguration.record_result(args[:configuration_id], error: error)
      unless error.is_a?(Discourse::InvalidParameters) ||
               error.is_a?(Salesforce::AmbiguousEmailMatch)
        raise
      end
      Rails.logger.warn(
        "CRM configured batch stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
      )
    end

    private

    def sync_hubspot_users(configuration, args)
      ids = Array(args[:user_ids]).map(&:to_i).uniq
      if ids.size > DiscourseCrm::ConfigurationScheduler::BATCH_SIZE
        raise Discourse::InvalidParameters.new(:user_ids)
      end
      ids.each_with_index do |user_id, index|
        begin
          Hubspot::ConfiguredUserSync.sync(configuration.id, user_id, reason: args[:reason])
        rescue Hubspot::RateLimitExceeded => error
          Jobs.enqueue_in(
            error.retry_after,
            :sync_salesforce_user_batch,
            args.merge(user_ids: ids.drop(index)),
          )
          return false
        rescue Hubspot::InvalidCredentials
          raise
        rescue => error
          DiscourseCrm::SyncConfiguration.record_result(configuration.id, user_id, error: error)
          unless error.is_a?(Discourse::InvalidParameters)
            Jobs.enqueue(
              :sync_salesforce_user,
              configuration_id: configuration.id,
              user_id: user_id,
              reason: args[:reason],
            )
          end
        end
      end
      true
    end
  end
end
