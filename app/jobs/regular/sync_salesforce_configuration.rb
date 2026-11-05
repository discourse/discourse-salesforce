# frozen_string_literal: true

module Jobs
  class SyncSalesforceConfiguration < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      configuration = Salesforce::SyncConfiguration.active.find_by(id: args[:configuration_id])
      return unless configuration&.reason_enabled?(args[:reason])
      ids =
        Salesforce::Person
          .eligible_group_members(configuration.configuration_groups.select(:group_id))
          .where("users.id > ?", args[:after_user_id].to_i)
          .order(:id)
          .limit(Salesforce::ConfiguredUserBatchSync::BATCH_SIZE)
          .pluck(:id)
      sync_ids = ids
      if args[:reason] == "scheduled"
        sync_ids = configuration.record_links.where(user_id: ids).order(:user_id).pluck(:user_id)
      end
      if sync_ids.present?
        Jobs.enqueue(
          :sync_salesforce_user_batch,
          configuration_id: configuration.id,
          user_ids: sync_ids,
          reason: args[:reason],
        )
      end
      if ids.size == Salesforce::ConfiguredUserBatchSync::BATCH_SIZE
        Jobs.enqueue(
          :sync_salesforce_configuration,
          configuration_id: configuration.id,
          after_user_id: ids.last,
          reason: args[:reason],
        )
      end
    end
  end
end
