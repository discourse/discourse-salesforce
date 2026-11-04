# frozen_string_literal: true

module Salesforce
  class ConfigurationScheduler
    def self.enqueue_user(user, reason:, group_id: nil, excluding_group_id: nil)
      GuidedSyncConfiguration.active.each do |record|
        next unless GuidedSyncConfiguration.reason_enabled?(record, reason)
        next if group_id && !GuidedSyncConfiguration.group_ids(record).include?(group_id)
        if excluding_group_id &&
             GuidedSyncConfiguration.group_ids(record).include?(excluding_group_id)
          next
        end
        unless GroupUser.exists?(
                 group_id: GuidedSyncConfiguration.group_ids(record),
                 user_id: user.id,
               )
          next
        end
        Jobs.enqueue(
          :sync_salesforce_user,
          user_id: user.id,
          configuration_id: record["id"],
          reason: reason,
        )
      end
    end

    def self.configuration_saved(record, previous:)
      if !previous || !previous["active"] || previous["schedule"] != record["schedule"]
        PluginStore.set(PLUGIN_NAME, "configuration_scheduled_at:#{record["id"]}", Time.now.to_i)
      end
      if record["backfill"] &&
           (
             !previous || !previous["active"] || !previous["backfill"] ||
               GuidedSyncConfiguration.group_ids(previous).sort !=
                 GuidedSyncConfiguration.group_ids(record).sort
           )
        Jobs.enqueue(
          :sync_salesforce_configuration,
          configuration_id: record["id"],
          reason: "backfill",
        )
      end
    end

    def self.enqueue_due
      Salesforce::GuidedSyncConfiguration.active.each do |configuration|
        now = Time.now.utc
        due =
          case configuration["schedule"]
          when "hourly"
            now.beginning_of_hour
          when "daily"
            now.beginning_of_day + 2.hours
          when "weekly"
            now.beginning_of_week + 2.hours
          end
        next unless due && now >= due
        DistributedMutex.synchronize("salesforce_configuration_schedule_#{configuration["id"]}") do
          key = "configuration_scheduled_at:#{configuration["id"]}"
          previous = PluginStore.get(PLUGIN_NAME, key)
          next if previous && previous.to_i >= due.to_i
          Jobs.enqueue(
            :sync_salesforce_configuration,
            configuration_id: configuration["id"],
            reason: "scheduled",
          )
          PluginStore.set(PLUGIN_NAME, key, Time.now.to_i)
        end
      end
    end
  end
end
