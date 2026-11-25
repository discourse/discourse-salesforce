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
      ::DiscourseCrm::SyncAttempt.track_batch(
        configuration,
        pending_ids,
        args[:scheduled_at],
      ) do |processed|
        ::Hubspot::ConfiguredUserBatchSync.sync(
          configuration,
          pending_ids.dup,
          reason: args[:reason],
          &processed
        )
      end
    rescue ::Hubspot::ConfiguredUserBatchSync::BatchReadFailure => failure
      error = failure.provider_error
      batch_error =
        ::Hubspot::InvalidApiResponse.new(
          "Invalid contact batch read response",
          status: error.status,
        )
      configuration&.record_batch_failure(pending_ids, error: error) do |user_id|
        user_id == failure.matched_user_id ? error : batch_error
      end
      raise if ::Hubspot::SyncFailure.retryable?(error)
      (pending_ids - [failure.matched_user_id]).each do |user_id|
        Jobs.enqueue(
          Jobs::Hubspot::PushUser,
          configuration_id: configuration.id,
          user_id: user_id,
          reason: args[:reason],
        )
      end
    rescue ::Hubspot::RateLimited => error
      ::Hubspot::SyncActivity.record_failure(configuration, nil, error)
      Jobs.enqueue_in(error.retry_after, self.class, args.merge(user_ids: pending_ids))
    rescue => error
      configuration&.record_batch_failure(pending_ids || args[:user_ids], error: error)
      raise if ::Hubspot::SyncFailure.retryable?(error)
      if error.is_a?(Discourse::InvalidParameters)
        Rails.logger.warn(
          "HubSpot batch stopped: configuration_id=#{args[:configuration_id]} error=#{error.class.name}",
        )
      end
    end
  end
end
