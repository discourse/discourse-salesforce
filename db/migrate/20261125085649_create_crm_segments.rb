# frozen_string_literal: true
class CreateCrmSegments < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_segments do |t|
      t.string :provider, null: false
      t.string :account, null: false
      t.string :name, null: false
      t.jsonb :conditions, null: false, default: {}
      t.integer :group_id
      t.boolean :remove_unmatched, null: false, default: false
      t.datetime :last_evaluated_at
      t.timestamps
    end
    add_index :crm_segments, %i[provider account]
    add_index :crm_segments, :group_id, unique: true, where: "group_id IS NOT NULL"

    create_table :crm_segment_members do |t|
      t.bigint :segment_id, null: false
      t.integer :user_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :crm_segment_members, %i[segment_id user_id], unique: true
    add_index :crm_segment_members, :user_id
  end
end
