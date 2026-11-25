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

        import = ::Hubspot::ContactImport.new(configuration)
        import.import_user(user) do |reasons|
          configuration.record_import_results(reasons, clear_errors_for: user.id)
        end
        return unless SiteSetting.crm_segments_enabled
        Jobs.enqueue(
          ::Jobs::DiscourseCrm::EvaluateSegments,
          provider: configuration.provider,
          account: configuration.account,
          user_ids: [user.id],
        )
      rescue ::Hubspot::RateLimited => error
        ::Hubspot::SyncActivity.record_failure(configuration, args[:user_id], error)
        Jobs.enqueue_in(error.retry_after, self.class, args)
      rescue => error
        configuration&.record_result(args[:user_id], error: error)
        unless error.is_a?(Discourse::InvalidParameters) ||
                 error.is_a?(::Hubspot::ApiValidationError) ||
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
