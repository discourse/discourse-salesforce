# frozen_string_literal: true

class CreateCrmSyncTables < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_sync_configurations do |t|
      t.string :provider, null: false
      t.string :account, null: false
      t.string :name, null: false
      t.string :kind, null: false, default: "users"
      t.string :object, null: false
      t.string :schedule, null: false
      t.boolean :backfill, null: false, default: false
      t.boolean :active, null: false, default: true
      t.jsonb :mappings, null: false, default: []
      t.datetime :last_scheduled_at
      t.datetime :last_synced_at
      t.string :last_error
      t.datetime :last_error_at
      t.timestamps
    end
    add_index :crm_sync_configurations, %i[provider account]

    create_table :crm_sync_configuration_groups do |t|
      t.bigint :configuration_id, null: false
      t.integer :group_id, null: false
    end
    add_index :crm_sync_configuration_groups,
              %i[configuration_id group_id],
              unique: true,
              name: "idx_crm_sync_configuration_groups_on_configuration_and_group"
    add_index :crm_sync_configuration_groups,
              %i[group_id configuration_id],
              unique: true,
              name: "idx_crm_sync_configuration_groups_on_group_and_configuration"

    create_table :crm_sync_states do |t|
      t.bigint :configuration_id, null: false
      t.integer :user_id, null: false
      t.string :fingerprint
      t.string :error
      t.datetime :error_at
      t.timestamps
    end
    add_index :crm_sync_states, %i[configuration_id user_id], unique: true

    create_table :crm_record_links do |t|
      t.string :provider, null: false
      t.string :account, null: false
      t.string :object, null: false
      t.integer :user_id, null: false
      t.string :external_id, null: false
      t.string :converted_from_id
      t.string :converted_to_object
      t.string :converted_to_id
      t.timestamps
    end
    add_index :crm_record_links, %i[provider account object user_id], unique: true
    add_index :crm_record_links, %i[provider account object external_id]
  end
end
