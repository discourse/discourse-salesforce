# frozen_string_literal: true

class RenameSalesforceCredentialSettings < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      UPDATE site_settings
      SET name = 'salesforce_consumer_key'
      WHERE name = 'salesforce_client_id'
    SQL

    execute <<~SQL
      UPDATE site_settings
      SET name = 'salesforce_server_key_contents'
      WHERE name = 'salesforce_rsa_private_key'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE site_settings
      SET name = 'salesforce_client_id'
      WHERE name = 'salesforce_consumer_key'
    SQL

    execute <<~SQL
      UPDATE site_settings
      SET name = 'salesforce_rsa_private_key'
      WHERE name = 'salesforce_server_key_contents'
    SQL
  end
end
