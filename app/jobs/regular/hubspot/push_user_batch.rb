# frozen_string_literal: true

module Jobs::Hubspot
  class PushUserBatch < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      configuration =
        ::DiscourseCrm::SyncConfiguration.active.outbound.find_by(
          id: args[:configuration_id],
          provider: "hubspot",
        )
      return unless configuration&.reason_enabled?(args[:reason])
      pending_ids = Array(args[:user_ids]).map(&:to_i).uniq
      if pending_ids.size > ::DiscourseCrm::ConfigurationScheduler::BATCH_SIZE
        raise Discourse::InvalidParameters.new(:user_ids)
      end
      ::Hubspot::ConfiguredUserBatchSync.sync(
        configuration,
        pending_ids.dup,
        reason: args[:reason],
      ) { |user_id| pending_ids.delete(user_id) }
      ::DiscourseCrm::SyncConfiguration.record_batch_success(configuration.id)
    rescue ::Hubspot::RateLimited => error
      Jobs.enqueue_in(error.retry_after, self.class, args.merge(user_ids: pending_ids))
    rescue => error
      ::DiscourseCrm::SyncConfiguration.record_batch_failure(
        args[:configuration_id],
        pending_ids || args[:user_ids],
        error: error,
      )
      raise if ::Hubspot::SyncFailure.retryable?(error)
      if error.is_a?(Discourse::InvalidParameters)
        Rails.logger.warn(
          "HubSpot batch stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
        )
      end
    end
  end
end
