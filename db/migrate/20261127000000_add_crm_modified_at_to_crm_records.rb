# frozen_string_literal: true

class AddCrmModifiedAtToCrmRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_records, :crm_modified_at, :datetime
  end
end
