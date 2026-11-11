# frozen_string_literal: true

class AddDirectionToCrmSyncConfigurations < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_sync_configurations, :direction, :string
    add_index :crm_sync_configurations,
              %i[provider account object],
              unique: true,
              where: "direction = 'inbound'",
              name: "index_crm_sync_configurations_on_inbound_scope"
  end
end
