# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Salesforce::RecordImport do
  include_context "with salesforce spec helper"

  fab!(:user) { Fabricate(:verified_user, name: "Old Name", email: "ada@example.com") }
  fab!(:other_user) { Fabricate(:verified_user, email: "grace@example.com") }

  let!(:configuration) { Fabricate(:salesforce_pull_configuration) }

  def record(id, email, modified: "2026-11-01T10:00:00.000+0000", **fields)
    {
      "attributes" => {
        "type" => configuration.object,
      },
      "Id" => id,
      "Email" => email,
      "SystemModstamp" => modified,
    }.merge(fields.stringify_keys)
  end

  def stub_query(records)
    stub_request(:get, query_path).with(query: hash_including({})).to_return(
      body: { totalSize: records.size, done: true, records: records }.to_json,
    )
  end

  def expect_soql(soql)
    expect(a_request(:get, query_path).with(query: { "q" => soql })).to have_been_made
  end

  describe "#fetch_page" do
    it "selects the mapped fields of records changed since the window, after the cursor" do
      stub_query([])

      described_class.new(configuration).fetch_page(
        since: Time.utc(2026, 11, 1, 9),
        after: %w[2026-11-01T10:00:00.000+0000 003A],
      )

      expect_soql(
        "SELECT Id, Email, SystemModstamp, Title, Name FROM Contact " \
          "WHERE SystemModstamp >= 2026-11-01T09:00:00Z AND " \
          "(SystemModstamp > 2026-11-01T10:00:00Z OR " \
          "(SystemModstamp = 2026-11-01T10:00:00Z AND Id > '003A')) " \
          "ORDER BY SystemModstamp, Id LIMIT 200",
      )
    end
    it "treats a short batch as the last page only when Salesforce says the query is done or it is empty" do
      import = described_class.new(configuration)
      response = { totalSize: 2, done: false, records: [record("003A", user.email)] }
      stub_request(:get, query_path).with(query: hash_including({})).to_return(
        body: response.to_json,
      )
      expect(import.fetch_page.last).to eq(false)

      stub_query([record("003A", user.email)])
      expect(import.fetch_page.last).to eq(true)

      stub_request(:get, query_path).with(query: hash_including({})).to_return(
        body: { totalSize: 0, done: false, records: [] }.to_json,
      )
      expect(import.fetch_page.last).to eq(true)
    end
  end

  describe "#import_page" do
    it "links users by email, keeps the mapped fields and fills mapped Discourse fields" do
      page =
        described_class.new(configuration).import_page(
          [
            record("003A", "ADA@example.com", Title: "CTO", Name: "Ada King", Phone: "123"),
            record("003B", "nobody@example.com", Title: "CEO", Name: "No One"),
          ],
        )

      expect(configuration.record_links.pluck(:user_id, :external_id)).to eq([[user.id, "003A"]])
      expect(configuration.records.pluck(:external_id, :data)).to eq(
        [["003A", { "Title" => "CTO", "Name" => "Ada King" }]],
      )
      expect(user.reload.name).to eq("Ada King")
      expect(page.reasons).to eq(user.id => "imported")
    end

    it "reads whether Leads were converted and unlinks a Lead once it is" do
      configuration.update!(
        object: "Lead",
        mappings: [{ "object" => "Lead", "source" => "Company" }],
      )
      import = described_class.new(configuration)
      stub_query([])
      import.fetch_page
      expect_soql(
        "SELECT Id, Email, SystemModstamp, Company, IsConverted FROM Lead " \
          "ORDER BY SystemModstamp, Id LIMIT 200",
      )
      import.import_page([record("00QA", user.email, Company: "Acme", IsConverted: false)])

      page = import.import_page([record("00QA", user.email, Company: "Acme", IsConverted: true)])

      expect(configuration.record_links).to be_empty
      expect(configuration.records).to be_empty
      expect(page.reasons).to eq(user.id => "contact_unlinked")
    end
  end

  describe "#import_user" do
    it "pulls the records carrying any of the user's emails and drops stale links" do
      UserEmail.create!(user: user, email: "o'hara@example.com")
      import = described_class.new(configuration)
      import.import_page([record("003OLD", user.email, Title: "Engineer")])
      stub_query([record("003A", "o'hara@example.com", Title: "CTO")])

      reasons = import.import_user(user)

      expect_soql(
        "SELECT Id, Email, SystemModstamp, Title, Name FROM Contact " \
          "WHERE Email IN ('ada@example.com','o\\'hara@example.com')",
      )
      expect(configuration.record_links.pluck(:external_id)).to eq(["003A"])
      expect(reasons).to eq(user.id => "imported_and_unlinked")
    end

    it "reads every batch of the user's records before dropping links" do
      import = described_class.new(configuration)
      import.import_page([record("003B", user.email)])
      stub_request(:get, query_path).with(query: hash_including({})).to_return(
        body: {
          done: false,
          nextRecordsUrl: "/services/data/v49.0/query/01g-2000",
          records: [record("003A", user.email)],
        }.to_json,
      )
      stub_request(:get, "#{query_path}01g-2000").to_return(
        body: { done: true, records: [record("003B", user.email)] }.to_json,
      )

      import.import_user(user)

      expect(configuration.record_links.pluck(:external_id)).to contain_exactly("003A", "003B")
    end
  end
end
