# frozen_string_literal: true

class RequireDirectionOnCrmSyncConfigurations < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE crm_sync_configurations SET direction = 'outbound' WHERE direction IS NULL"
    change_column_null :crm_sync_configurations, :direction, false
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
