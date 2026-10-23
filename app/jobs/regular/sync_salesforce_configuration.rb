# frozen_string_literal: true

module Jobs
  class SyncSalesforceConfiguration < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      configuration =
        Salesforce::GuidedSyncConfiguration.active.find do |record|
          record["id"] == args[:configuration_id]
        end
      unless configuration &&
               Salesforce::GuidedSyncConfiguration.reason_enabled?(configuration, args[:reason])
        return
      end
      ids =
        GroupUser
          .where(group_id: configuration["group_id"])
          .where(user_id: Salesforce::Person.eligible_users.select(:id))
          .where("user_id > ?", args[:after_user_id].to_i)
          .order(:user_id)
          .limit(100)
          .pluck(:user_id)
      ids.each do |user_id|
        Jobs.enqueue(
          :sync_salesforce_user,
          configuration_id: configuration["id"],
          user_id: user_id,
          reason: args[:reason],
        )
      end
      if ids.size == 100
        Jobs.enqueue(
          :sync_salesforce_configuration,
          configuration_id: configuration["id"],
          after_user_id: ids.last,
          reason: args[:reason],
        )
      end
    end
  end
end
