# frozen_string_literal: true

class AddObjectToHubspotMappings < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE crm_sync_configurations
      SET mappings = (
        SELECT COALESCE(jsonb_agg(m.value || '{"object":"contact"}' ORDER BY m.ordinality), '[]'::jsonb)
        FROM jsonb_array_elements(mappings) WITH ORDINALITY m
      )
      WHERE provider = 'hubspot' AND direction = 'inbound'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
