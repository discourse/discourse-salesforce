# frozen_string_literal: true
class AddFlairToCrmSegments < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_segments, :flair_enabled, :boolean, null: false, default: false
    add_column :crm_segments, :flair_text_property, :string
    add_column :crm_segments, :flair_properties, :jsonb, null: false, default: []
    add_column :crm_segments, :flair_group_ids, :integer, array: true, null: false, default: []
  end
end
