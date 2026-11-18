# frozen_string_literal: true

module Jobs::DiscourseCrm
  class SyncOutboundConfiguration < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      configuration =
        ::DiscourseCrm::SyncConfiguration.active.outbound.find_by(id: args[:configuration_id])
      return unless configuration&.reason_enabled?(args[:reason])
      ids =
        ::DiscourseCrm::UserEligibility
          .eligible_group_members(configuration.configuration_groups.select(:group_id))
          .where("users.id > ?", args[:after_user_id].to_i)
          .order(:id)
          .limit(::DiscourseCrm::ConfigurationScheduler::BATCH_SIZE)
          .pluck(:id)
      sync_ids = ids
      if args[:reason] == "scheduled"
        linked_ids = configuration.record_links.where(user_id: ids).pluck(:user_id)
        failures =
          configuration
            .sync_states
            .where(user_id: ids)
            .where.not(error: nil)
            .pluck(:user_id, :error)
        permanent_ids =
          failures.filter_map do |user_id, error|
            user_id if configuration.flow.permanent_sync_errors.include?(error)
          end
        sync_ids = (ids & (linked_ids | failures.map(&:first))) - permanent_ids
      end
      if sync_ids.present?
        Jobs.enqueue(
          configuration.flow.batch_job,
          configuration_id: configuration.id,
          user_ids: sync_ids,
          reason: args[:reason],
        )
      end
      if ids.size == ::DiscourseCrm::ConfigurationScheduler::BATCH_SIZE
        Jobs.enqueue(
          Jobs::DiscourseCrm::SyncOutboundConfiguration,
          configuration_id: configuration.id,
          after_user_id: ids.last,
          reason: args[:reason],
        )
      end
    end
  end
end
