# frozen_string_literal: true

class AllowMultipleRecordLinksPerUser < ActiveRecord::Migration[8.1]
  def up
    remove_index :crm_record_links, %i[provider account object user_id]
    add_index :crm_record_links,
              %i[provider account object user_id external_id],
              unique: true,
              name: "index_crm_record_links_on_scope_user_and_external_id"
    add_index :crm_record_links,
              %i[provider account object user_id],
              unique: true,
              where: "provider = 'salesforce'",
              name: "index_crm_record_links_on_salesforce_user"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
