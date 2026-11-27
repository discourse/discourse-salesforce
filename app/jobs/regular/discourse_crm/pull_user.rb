# frozen_string_literal: true

module Jobs::DiscourseCrm
  # Pulls one user's CRM records, for example after they confirm or change their email.
  class PullUser < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      configuration =
        ::DiscourseCrm::SyncConfiguration.active.inbound.find_by(id: args[:configuration_id])
      return unless configuration&.reason_enabled?(args[:reason])
      flow = configuration.flow
      return unless flow.user_job
      user = ::DiscourseCrm::UserEligibility.eligible_users.find_by(id: args[:user_id])
      unless user
        # Users who can no longer be matched lose their links.
        ::DiscourseCrm::RecordImport
          .new(configuration)
          .unlink_ineligible([args[:user_id]]) do |unlinked|
            configuration.record_import_results(unlinked)
          end
        return
      end

      affected_user_ids = [user.id]
      flow
        .importer
        .new(configuration)
        .import_user(user) do |reasons, page|
          # A contact that moved to this user leaves its former owner's segments to update.
          affected_user_ids |= page.removed_user_ids
          configuration.record_import_results(
            reasons,
            clear_errors_for: user.id,
            errors: page.destination_errors,
          )
        end
      configuration.evaluate_segments_later(user_ids: affected_user_ids)
    rescue ::DiscourseCrm::RecordImport::Paused
      nil
    rescue => error
      # Providers raise errors with `retry_after` when their API asks the caller to wait.
      if error.respond_to?(:retry_after)
        ::DiscourseCrm::SyncAttempt.record(configuration, args[:user_id], error: error)
        return Jobs.enqueue_in(error.retry_after, self.class, args)
      end
      configuration&.record_result(args[:user_id], error: error)
      raise unless flow&.stops_pull?(error)
      Rails.logger.warn(
        "CRM user pull stopped: configuration_id=#{args[:configuration_id]} user_id=#{args[:user_id]} error=#{error.class.name}",
      )
    end
  end
end
