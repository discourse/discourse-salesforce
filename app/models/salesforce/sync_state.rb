# frozen_string_literal: true

module Salesforce
  class SyncState < ActiveRecord::Base
    self.table_name = "crm_sync_states"

    belongs_to :configuration, class_name: "Salesforce::GuidedSyncConfiguration"

    def self.store(configuration_id, user_id, **attributes)
      now = Time.zone.now
      upsert(
        { configuration_id:, user_id:, created_at: now, updated_at: now }.merge(attributes),
        unique_by: %i[configuration_id user_id],
        update_only: attributes.keys,
      )
    end
  end
end
