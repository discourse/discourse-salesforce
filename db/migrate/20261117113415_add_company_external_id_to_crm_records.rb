# frozen_string_literal: true

class AddCompanyExternalIdToCrmRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_records, :company_external_id, :string
    add_index :crm_records, %i[provider account company_external_id]
  end
end
