# frozen_string_literal: true

class CreateCrmRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_records do |t|
      t.string :provider, null: false
      t.string :account, null: false
      t.string :object, null: false
      t.string :external_id, null: false
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end
    add_index :crm_records, %i[provider account object external_id], unique: true
  end
end
