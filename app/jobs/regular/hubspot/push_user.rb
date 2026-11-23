# frozen_string_literal: true

module Jobs::Hubspot
  class PushUser < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      ::Hubspot::ConfiguredUserSync.sync(
        args[:configuration_id],
        args[:user_id],
        reason: args[:reason],
      )
    rescue ::Hubspot::RateLimited => error
      Jobs.enqueue_in(error.retry_after, self.class, args)
    rescue => error
      raise if ::Hubspot::SyncFailure.retryable?(error)
    end
  end
end
