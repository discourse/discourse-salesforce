# frozen_string_literal: true

class CreateCrmSyncAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_sync_attempts do |t|
      t.bigint :configuration_id
      t.integer :user_id
      t.string :provider, null: false
      t.string :direction, null: false
      t.string :object, null: false
      t.string :outcome, null: false
      t.string :reason, null: false
      t.string :error_class
      t.jsonb :diagnostics, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :crm_sync_attempts, %i[created_at id]
    add_index :crm_sync_attempts, %i[user_id created_at id]
    add_index :crm_sync_attempts, %i[provider created_at id]
    add_index :crm_sync_attempts, %i[outcome created_at id]
  end
end
