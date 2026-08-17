# frozen_string_literal: true
class AddUniqueIndexToSalesforceCasesTopicId < ActiveRecord::Migration[8.0]
  def up
    # Concurrent case syncs could each insert a row for the same topic, every
    # insert also creating a Salesforce case. Keep the row most recently synced
    # with Salesforce; the others only ever pointed at abandoned duplicates.
    execute <<~SQL
      DELETE FROM salesforce_cases
      WHERE id NOT IN (
        SELECT DISTINCT ON (topic_id) id
        FROM salesforce_cases
        ORDER BY topic_id, last_synced_at DESC NULLS LAST, id DESC
      )
    SQL

    add_index :salesforce_cases, :topic_id, unique: true, if_not_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
