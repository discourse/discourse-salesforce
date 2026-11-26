# frozen_string_literal: true

module DiscourseCrm
  class ConfigurationScheduler
    BATCH_SIZE = 100

    def self.enqueue_user(user, reason:, inbound:, group_id: nil, excluding_group_id: nil)
      member_group_ids = GroupUser.where(user_id: user.id).select(:group_id)
      configurations =
        SyncConfiguration.active.outbound.where(id: configuration_ids_for(member_group_ids))
      configurations = configurations.where(id: configuration_ids_for(group_id)) if group_id
      if excluding_group_id
        configurations = configurations.where.not(id: configuration_ids_for(excluding_group_id))
      end
      enqueue_user_jobs(configurations, user, reason)
      return unless inbound
      enqueue_user_jobs(SyncConfiguration.active.inbound, user, reason)
    end

    def self.configuration_saved(configuration, group_ids_changed:)
      activated =
        configuration.previously_new_record? ||
          configuration.saved_change_to_active?(from: false, to: true)
      connection_changed = configuration.saved_change_to_account?
      if activated || connection_changed || configuration.saved_change_to_schedule?
        configuration.update_column(:last_scheduled_at, Time.zone.now)
      end
      # Scheduled pulls only see changed records, so new pull mappings need every record again.
      remapped_pull = configuration.inbound? && mappings_changed?(configuration)
      if configuration.backfill &&
           (
             activated || connection_changed || group_ids_changed || remapped_pull ||
               configuration.saved_change_to_backfill?(from: false, to: true)
           )
        Jobs.enqueue(
          configuration.flow.configuration_job,
          configuration_id: configuration.id,
          reason: "backfill",
        )
      elsif configuration.outbound? && !activated && !connection_changed
        retry_failed_users(configuration)
      end
    end

    # Mapping ids only order the form's rows, so renumbering them changes nothing pulled.
    def self.mappings_changed?(configuration)
      change = configuration.saved_change_to_mappings
      return false unless change
      before, after =
        change.map { |mappings| Array(mappings).map { |mapping| mapping.except("id") } }
      before != after
    end
    private_class_method :mappings_changed?

    def self.retry_failed_users(configuration)
      failed_ids = configuration.sync_states.where.not(error: nil).select(:user_id)
      UserEligibility
        .eligible_group_members(configuration.configuration_groups.select(:group_id))
        .where(id: failed_ids)
        .in_batches(of: BATCH_SIZE) do |users|
          Jobs.enqueue(
            configuration.flow.batch_job,
            configuration_id: configuration.id,
            user_ids: users.pluck(:id),
            reason: "retry",
          )
        end
    end
    private_class_method :retry_failed_users

    def self.enqueue_due
      now = Time.now.utc
      SyncConfiguration
        .active
        .where.not(schedule: "manual")
        .find_each do |configuration|
          due =
            case configuration.schedule
            when "hourly"
              now.beginning_of_hour
            when "daily"
              now.beginning_of_day + 2.hours
            when "weekly"
              now.beginning_of_week + 2.hours
            end
          next unless due && now >= due
          claimed =
            SyncConfiguration
              .where(id: configuration.id)
              .where("last_scheduled_at IS NULL OR last_scheduled_at < ?", due)
              .update_all(last_scheduled_at: now)
          next if claimed == 0
          Jobs.enqueue(
            configuration.flow.configuration_job,
            configuration_id: configuration.id,
            reason: "scheduled",
            **(configuration.outbound? ? { scheduled_at: now.iso8601(6) } : {}),
          )
        end
    end

    def self.enqueue_user_jobs(configurations, user, reason)
      configurations.find_each do |configuration|
        user_job = configuration.flow.user_job
        next unless user_job && configuration.reason_enabled?(reason)
        Jobs.enqueue(user_job, user_id: user.id, configuration_id: configuration.id, reason: reason)
      end
    end
    private_class_method :enqueue_user_jobs

    def self.configuration_ids_for(group_ids)
      SyncConfigurationGroup.where(group_id: group_ids).select(:configuration_id)
    end
    private_class_method :configuration_ids_for
  end
end
