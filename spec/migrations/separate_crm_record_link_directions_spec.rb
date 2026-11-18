# frozen_string_literal: true

require_relative "../../db/migrate/20261118030134_separate_crm_record_link_directions"

RSpec.describe SeparateCrmRecordLinkDirections do
  it "preserves inbound and legacy outbound links to the same HubSpot contact" do
    connection = ActiveRecord::Base.connection
    connection.remove_column(:crm_record_links, :direction)
    connection.add_index(
      :crm_record_links,
      %i[provider account object user_id external_id],
      unique: true,
      name: :index_crm_record_links_on_scope_user_and_external_id,
    )
    connection.add_index(
      :crm_record_links,
      %i[provider account object user_id],
      unique: true,
      where: "provider = 'salesforce'",
      name: :index_crm_record_links_on_salesforce_user,
    )
    connection.execute <<~SQL
      INSERT INTO crm_record_links (provider, account, object, user_id, external_id, created_at, updated_at)
      VALUES ('hubspot', '12345', 'contact', 42, '501', NOW(), NOW()),
             ('hubspot', '12345', 'Contact', 42, '501', NOW(), NOW())
    SQL

    migration = described_class.new
    migration.suppress_messages { migration.up }

    links =
      connection.select_rows(
        "SELECT object, direction, external_id FROM crm_record_links WHERE user_id = 42",
      )
    expect(links).to contain_exactly(%w[contact inbound 501], %w[contact outbound 501])

    connection.execute <<~SQL
      INSERT INTO crm_record_links (provider, account, object, user_id, external_id, created_at, updated_at)
      VALUES ('hubspot', '12345', 'contact', 43, '504', NOW(), NOW())
    SQL
    expect(
      connection.select_value("SELECT direction FROM crm_record_links WHERE external_id = '504'"),
    ).to eq("outbound")
  end
end
