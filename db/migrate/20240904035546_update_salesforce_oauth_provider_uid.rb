# frozen_string_literal: true

class UpdateSalesforceOauthProviderUid < ActiveRecord::Migration[7.1]
  def up
    execute <<-SQL.squish
      UPDATE user_associated_accounts
      SET provider_uid = REGEXP_REPLACE(provider_uid, '^https://login\\.salesforce\\.com/id/[^/]+/', '')
      WHERE provider_name = 'salesforce';
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
