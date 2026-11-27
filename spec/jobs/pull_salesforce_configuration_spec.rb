# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::PullSalesforceConfiguration do
  include_context "with salesforce spec helper"

  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }

  let!(:configuration) { Fabricate(:salesforce_pull_configuration) }

  before do
    SiteSetting.enable_guided_sync_configuration = true
    freeze_time Time.utc(2026, 11, 2, 12)
    described_class.clear
  end

  def contact(id, email, modified: "2026-11-01T10:00:00.000+0000")
    {
      "Id" => id,
      "Email" => email,
      "SystemModstamp" => modified,
      "Title" => "CTO",
      "Name" => "Ada",
    }
  end

  def stub_page(records, matching: nil)
    request = stub_request(:get, query_path)
    request = request.with(query: hash_including("q" => matching)) if matching
    request.to_return(body: { totalSize: records.size, done: true, records: records }.to_json)
  end

  it "continues after the last record of a full page and finishes on a shorter one" do
    stub_const(Salesforce::RecordImport, :PAGE_SIZE, 2) do
      stub_page(
        [contact("003A", user.email), contact("003B", "nobody@example.com")],
        matching: /\ASELECT .* FROM Contact ORDER BY/,
      )
      described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

      args = described_class.jobs.last["args"].first
      expect(args).to include(
        "reason" => "backfill",
        "after" => %w[2026-11-01T10:00:00.000+0000 003B],
        "history_result" => "recorded",
        "started_at" => "2026-11-02T12:00:00Z",
      )
      expect(configuration.reload.last_synced_at).to be_nil

      stub_page([], matching: /Id > '003B'/)
      described_class.new.execute(args.symbolize_keys)
    end

    expect(configuration.record_link_for(user.id).external_id).to eq("003A")
    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
    expect(DiscourseCrm::SyncAttempt.where(user_id: nil).count).to eq(0)
  end

  it "drops a queued page whose cursor came from another Salesforce account" do
    described_class.new.execute(
      configuration_id: configuration.id,
      account: "https://previous.my.salesforce.com/",
      reason: "backfill",
      after: %w[2026-11-01T10:00:00.000+0000 003A],
    )

    expect(a_request(:get, /#{query_path}/)).not_to have_been_made
    expect(configuration.reload.last_synced_at).to be_nil
  end

  it "fails instead of requesting the same page again when the cursor does not move" do
    stub_const(Salesforce::RecordImport, :PAGE_SIZE, 1) do
      stub_page([contact("003A", user.email)], matching: /Id > '003A'/)

      expect {
        described_class.new.execute(
          configuration_id: configuration.id,
          reason: "backfill",
          after: %w[2026-11-01T10:00:00.000+0000 003A],
        )
      }.to raise_error(Salesforce::InvalidApiResponse, /did not advance/)
    end
    expect(described_class.jobs).to be_empty
  end

  it "pulls records changed since shortly before the last pull" do
    configuration.update!(last_synced_at: Time.utc(2026, 11, 1, 12))
    stub_page([], matching: /WHERE SystemModstamp >= 2026-11-01T11:55:00Z ORDER BY/)

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
    expect(
      DiscourseCrm::SyncAttempt.where(configuration_id: configuration.id).pluck(:reason),
    ).to eq(["no_contacts"])
  end

  it "links nobody when the pull is deleted while a page is in flight" do
    stub_request(:get, query_path)
      .with(query: hash_including({}))
      .to_return do
        DiscourseCrm::SyncConfiguration.where(id: configuration.id).delete_all
        { body: { done: true, records: [contact("003A", user.email)] }.to_json }
      end

    expect {
      described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    }.not_to raise_error
    expect(configuration.record_links).to be_empty
  end

  it "stops without retrying when Salesforce rejects the query or the credentials" do
    stub_request(:get, query_path).with(query: hash_including({})).to_return(
      status: 400,
      body: [{ errorCode: "INVALID_FIELD", message: "No such column 'Region__c'" }].to_json,
    )
    expect {
      described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    }.not_to raise_error
    expect(configuration.reload.last_error).to eq("Salesforce::InvalidApiResponse")

    SiteSetting.salesforce_consumer_key = ""
    expect {
      described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    }.not_to raise_error
    expect(configuration.reload.last_error).to eq("Salesforce::InvalidCredentials")
  end
end
