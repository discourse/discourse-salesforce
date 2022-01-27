# frozen_string_literal: true

class CreateSalesforceCasesTables < ActiveRecord::Migration[6.0]
  def change
    create_table :salesforce_cases do |t|
      t.string :uid, null: true, index: true, unique: true
      t.integer :topic_id, null: false, unique: true
      t.string :contact_id, null: true
      t.string :number
      t.string :subject
      t.string :description
      t.string :status
      t.datetime :last_synced_at
      t.timestamps
    end
  end
end
