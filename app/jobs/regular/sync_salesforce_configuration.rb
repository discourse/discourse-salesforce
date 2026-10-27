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
        Salesforce::Person
          .eligible_group_members(Salesforce::GuidedSyncConfiguration.group_ids(configuration))
          .where("users.id > ?", args[:after_user_id].to_i)
          .order(:id)
          .limit(Salesforce::ConfiguredUserBatchSync::BATCH_SIZE)
          .pluck(:id)
      if ids.present?
        Jobs.enqueue(
          :sync_salesforce_user_batch,
          configuration_id: configuration["id"],
          user_ids: ids,
          reason: args[:reason],
        )
      end
      if ids.size == Salesforce::ConfiguredUserBatchSync::BATCH_SIZE
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
