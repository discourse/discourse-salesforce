# frozen_string_literal: true

module Jobs
  class SyncSalesforceConfigurations < ::Jobs::Scheduled
    every 1.hour

    def execute(args)
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
          previous = PluginStore.get(Salesforce::PLUGIN_NAME, key)
          next if previous && previous.to_i >= due.to_i
          Jobs.enqueue(
            :sync_salesforce_configuration,
            configuration_id: configuration["id"],
            reason: "scheduled",
          )
          PluginStore.set(Salesforce::PLUGIN_NAME, key, Time.now.to_i)
        end
      end
    end
  end
end
