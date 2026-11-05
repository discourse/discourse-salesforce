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

# == Schema Information
#
# Table name: crm_sync_states
#
#  id               :bigint           not null, primary key
#  error            :string
#  error_at         :datetime
#  fingerprint      :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  configuration_id :bigint           not null
#  user_id          :integer          not null
#
# Indexes
#
#  index_crm_sync_states_on_configuration_id_and_user_id  (configuration_id,user_id) UNIQUE
#
