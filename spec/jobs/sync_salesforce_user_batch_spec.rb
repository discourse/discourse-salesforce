# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::SyncSalesforceUserBatch do
  include_context "with salesforce spec helper"

  fab!(:group)
  fab!(:user) { Fabricate(:user, name: "Alex Morgan") }
  fab!(:other_user) { Fabricate(:user, name: "Maya Chen") }
  let(:configuration) do
    {
      "id" => "batch",
      "kind" => "users",
      "active" => true,
      "group_id" => group.id,
      "group" => group.name,
      "object" => "Contact",
      "instance_url" => instance_url,
      "backfill" => true,
      "schedule" => "daily",
      "mappings" => [
        { "source" => "last", "destination" => "LastName", "policy" => "keep" },
        {
          "source" => "static",
          "value" => "Discourse",
          "destination" => "LeadSource",
          "policy" => "overwrite",
        },
      ],
    }
  end
  let(:fields) do
    %w[Email LastName LeadSource].map do |name|
      { name: name, type: "string", createable: true, updateable: true }
    end
  end
  let(:collection_url) { "#{instance_url}services/data/v49.0/composite/sobjects" }

  before do
    SiteSetting.enable_guided_sync_configuration = true
    group.add(user)
    group.add(other_user)
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    stub_request(:get, "#{api_path}/Contact/describe").to_return(body: { fields: fields }.to_json)
    Jobs::SyncSalesforceUser.clear
  end

  def run_batch
    described_class.new.execute(
      configuration_id: "batch",
      user_ids: [user.id, other_user.id],
      reason: "backfill",
    )
  end

  it "sends each user's stored metrics and configured custom field values in the batch" do
    custom_field = Fabricate(:user_field, name: "Role")
    user.custom_fields["user_field_#{custom_field.id}"] = "Engineer"
    user.save_custom_fields
    user.user_stat.update!(time_read: 150)
    other_user.custom_fields["user_field_#{custom_field.id}"] = "Designer"
    other_user.save_custom_fields
    other_user.user_stat.update!(time_read: 300)
    configuration["mappings"].concat(
      [
        { "source" => "read_time", "destination" => "Read_Minutes__c", "policy" => "overwrite" },
        {
          "source" => "user_field_#{custom_field.id}",
          "destination" => "Role__c",
          "policy" => "overwrite",
        },
      ],
    )
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    fields.concat(
      [
        { name: "Read_Minutes__c", type: "double", createable: true, updateable: true },
        { name: "Role__c", type: "string", createable: true, updateable: true },
      ],
    )
    stub_request(:get, "#{api_path}/Contact/describe").to_return(body: { fields: fields }.to_json)
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    sent = nil
    stub_request(:post, collection_url)
      .with do |request|
        sent = JSON.parse(request.body)
        true
      end
      .to_return(body: [{ id: "one", success: true }, { id: "two", success: true }].to_json)
    run_batch
    expect(
      sent["records"].map { |record| record.slice("Email", "Read_Minutes__c", "Role__c") },
    ).to eq(
      [
        { "Email" => user.email, "Read_Minutes__c" => 2.5, "Role__c" => "Engineer" },
        { "Email" => other_user.email, "Read_Minutes__c" => 5, "Role__c" => "Designer" },
      ],
    )
  end

  it "batches reads and creates, saves links, and skips unchanged records on retry" do
    query =
      "SELECT Id,Email,LastName,LeadSource FROM Contact WHERE Email IN ('#{user.email}','#{other_user.email}')"
    lookup =
      stub_request(:get, query_path).with(query: { q: query }).to_return(
        body: { records: [] }.to_json,
      )
    create =
      stub_request(:post, collection_url).with(
        body: {
          allOrNone: false,
          records: [
            {
              attributes: {
                type: "Contact",
              },
              Email: user.email,
              LastName: "Morgan",
              LeadSource: "Discourse",
            },
            {
              attributes: {
                type: "Contact",
              },
              Email: other_user.email,
              LastName: "Chen",
              LeadSource: "Discourse",
            },
          ],
        },
      ).to_return(
        body: [{ id: "contact1", success: true }, { id: "contact2", success: true }].to_json,
      )
    run_batch
    expect(create).to have_been_requested.once
    expect(lookup).to have_been_requested.once
    expect(a_request(:get, "#{api_path}/Contact/describe")).to have_been_requested.once
    expect([user.reload.salesforce_contact_id, other_user.reload.salesforce_contact_id]).to eq(
      %w[contact1 contact2],
    )
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [
          { Id: "contact1", Email: user.email, LastName: "CRM name", LeadSource: "Discourse" },
          { Id: "contact2", Email: other_user.email, LastName: "Chen", LeadSource: "Discourse" },
        ],
      }.to_json,
    )
    run_batch
    expect(create).to have_been_requested.once
    expect(a_request(:patch, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
  end

  it "preserves Salesforce values and retries only failed collection entries" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [
          { Id: "contact1", Email: user.email, LastName: "CRM name", LeadSource: "Web" },
          { Id: "contact2", Email: other_user.email, LastName: "", LeadSource: "Web" },
        ],
      }.to_json,
    )
    update =
      stub_request(:patch, collection_url).with(
        body: {
          allOrNone: false,
          records: [
            { attributes: { type: "Contact" }, Id: "contact1", LeadSource: "Discourse" },
            {
              attributes: {
                type: "Contact",
              },
              Id: "contact2",
              LastName: "Chen",
              LeadSource: "Discourse",
            },
          ],
        },
      ).to_return(
        body: [
          { id: "contact1", success: true },
          { success: false, errors: [{ statusCode: "UNABLE_TO_LOCK_ROW" }] },
        ].to_json,
      )
    run_batch
    expect(update).to have_been_requested.once
    expect(user.reload.salesforce_contact_id).to eq("contact1")
    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] }).to eq(
      [other_user.id],
    )
  end

  it "defers ambiguous matches and missing linked records to individual jobs" do
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      "configured_user_link:Contact:#{other_user.id}",
      { id: "missing", instance: instance_url },
    )
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [{ Id: "contact1", Email: user.email }, { Id: "contact2", Email: user.email }],
      }.to_json,
    )
    run_batch
    expect(
      Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] },
    ).to contain_exactly(user.id, other_user.id)
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(a_request(:patch, collection_url)).not_to have_been_made
  end

  it "rechecks membership and configuration activation before making requests" do
    group.remove(user)
    other_user.update!(active: false)
    run_batch
    configuration["active"] = false
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    group.add(user)
    run_batch
    expect(a_request(:get, "#{api_path}/Contact/describe")).not_to have_been_made
  end

  it "follows query pages and uses saved IDs after an email change" do
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      "configured_user_link:Contact:#{user.id}",
      { id: "contact1", instance: instance_url },
    )
    lookup =
      stub_request(:get, query_path).with(
        query: hash_including("q" => /Id IN \(\x27contact1\x27\)/),
      ).to_return(
        body: {
          records: [
            {
              Id: "contact1",
              Email: "old@example.com",
              LastName: "CRM name",
              LeadSource: "Discourse",
            },
          ],
          nextRecordsUrl: "/services/data/v49.0/query/next-page",
        }.to_json,
      )
    page =
      stub_request(:get, "#{query_path}next-page").to_return(
        body: {
          records: [
            { Id: "contact2", Email: other_user.email, LastName: "Chen", LeadSource: "Discourse" },
          ],
        }.to_json,
      )
    run_batch
    expect(lookup).to have_been_requested.once
    expect(page).to have_been_requested.once
    expect(user.reload.salesforce_contact_id).to eq("contact1")
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
  end

  it "falls back to individual retries after an uncertain collection response" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    stub_request(:post, collection_url).to_timeout
    run_batch
    expect(
      Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] },
    ).to contain_exactly(user.id, other_user.id)
  end
  it "records lookup failures and raises for Sidekiq to retry the batch" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      status: 503,
      body: "Unavailable",
    )

    expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse)
    status = PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:batch")
    expect(status).to include("error" => "Salesforce::InvalidApiResponse", "user_id" => user.id)
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
    expect(a_request(:post, collection_url)).not_to have_been_made
  end
end
