# frozen_string_literal: true
class AddPropertyMetadataToCrmSyncConfigurations < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_sync_configurations, :property_metadata, :jsonb, null: false, default: {}
  end
end
