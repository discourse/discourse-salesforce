# frozen_string_literal: true

module Jobs
  module Hubspot
    class SyncUser < ::Jobs::Base
      sidekiq_options retry: 5

      def execute(args)
        configuration =
          ::DiscourseCrm::SyncConfiguration.active.inbound.find_by(
            id: args[:configuration_id],
            provider: "hubspot",
          )
        return unless configuration&.reason_enabled?(args[:reason])
        user = ::DiscourseCrm::UserEligibility.eligible_users.find_by(id: args[:user_id])
        return unless user

        ::Hubspot::ContactImport.new(configuration).import_user(user)
        ::DiscourseCrm::SyncState.where(
          configuration_id: configuration.id,
          user_id: user.id,
        ).update_all(error: nil, error_at: nil)
      rescue ::Hubspot::RateLimited => error
        Jobs.enqueue_in(error.retry_after, self.class, args)
      rescue => error
        ::DiscourseCrm::SyncConfiguration.record_result(
          args[:configuration_id],
          args[:user_id],
          error: error,
        )
        unless error.is_a?(Discourse::InvalidParameters) ||
                 error.is_a?(::Hubspot::DailyQuotaExceeded)
          raise
        end
        Rails.logger.warn(
          "HubSpot user import stopped: configuration_id=#{args[:configuration_id]} user_id=#{args[:user_id]} error=#{error.class.name}",
        )
      end
    end
  end
end
