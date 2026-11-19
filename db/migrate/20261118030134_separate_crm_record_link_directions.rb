# frozen_string_literal: true

class SeparateCrmRecordLinkDirections < ActiveRecord::Migration[8.1]
  def up
    add_column :crm_record_links, :direction, :string, null: false, default: "outbound"
    execute "UPDATE crm_record_links SET direction = 'inbound' WHERE provider = 'hubspot' AND object = 'contact'"
    remove_index :crm_record_links, name: :index_crm_record_links_on_scope_user_and_external_id
    execute "UPDATE crm_record_links SET object = 'contact' WHERE provider = 'hubspot' AND object = 'Contact'"
    execute "UPDATE crm_sync_configurations SET object = 'contact' WHERE provider = 'hubspot' AND object = 'Contact'"
    remove_index :crm_record_links, name: :index_crm_record_links_on_salesforce_user
    add_index :crm_record_links,
              %i[provider account object direction user_id external_id],
              unique: true,
              name: :index_crm_record_links_on_scope_user_and_external_id
    add_index :crm_record_links,
              %i[provider account object user_id],
              unique: true,
              where: "direction = 'outbound'",
              name: :index_crm_record_links_on_outbound_user
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
