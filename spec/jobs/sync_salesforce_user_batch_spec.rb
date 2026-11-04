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
      "provider" => "salesforce",
      "active" => true,
      "group_ids" => [group.id],
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
    user.activate
    other_user.activate
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

  it "excludes an unconfirmed email while syncing verified users" do
    user.email_tokens.delete_all
    user.email_tokens.create!(email: user.email, scope: EmailToken.scopes[:signup])
    expect(user.reload).to be_active
    expect(user.email_confirmed?).to eq(false)
    lookup =
      stub_request(:get, query_path).with(
        query: {
          q:
            "SELECT Id,Email,LastName,LeadSource FROM Contact WHERE Email IN ('#{other_user.email}')",
        },
      ).to_return(body: { records: [] }.to_json)
    create =
      stub_request(:post, collection_url)
        .with do |request|
          JSON.parse(request.body)["records"].map { |record| record["Email"] } == [other_user.email]
        end
        .to_return(body: [{ id: "contact2", success: true }].to_json)

    run_batch

    expect(lookup).to have_been_requested.once
    expect(create).to have_been_requested.once
    expect(user.reload.salesforce_contact_id).to be_nil
    expect(other_user.reload.salesforce_contact_id).to eq("contact2")
  end

  it "pins email matches before a failed batch update and reconciles them after an email change" do
    other_user.update!(active: false)
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [{ Id: "contact1", Email: user.email, LastName: "Morgan", LeadSource: "Web" }],
      }.to_json,
    )
    stub_request(:patch, collection_url).to_timeout
    fingerprint_key = "configuration_user_fingerprint:batch:#{user.id}"
    PluginStore.set(Salesforce::PLUGIN_NAME, fingerprint_key, "previous")

    run_batch

    link =
      Salesforce::RecordLink.new(
        provider: "salesforce",
        account: instance_url,
        object: "Contact",
        user_id: user.id,
      )
    expect(link.read["id"]).to eq("contact1")
    expect(user.reload.salesforce_contact_id).to be_nil
    expect(PluginStore.get(Salesforce::PLUGIN_NAME, fingerprint_key)).to eq("previous")
    user.primary_email.update!(email: "changed@example.com")
    user.reload.activate
    stub_request(:get, "#{api_path}/Contact/contact1").to_return(
      body: { Id: "contact1", LastName: "Morgan", LeadSource: "Web" }.to_json,
    )
    update = stub_request(:patch, "#{api_path}/Contact/contact1").to_return(status: 204)

    Jobs::SyncSalesforceUser.new.execute(
      Jobs::SyncSalesforceUser.jobs.first["args"].first.symbolize_keys,
    )

    expect(update).to have_been_requested.once
    expect(a_request(:post, "#{api_path}/Contact")).not_to have_been_made
    expect(user.reload.salesforce_contact_id).to eq("contact1")
  end

  it "sends each user's stored metrics and configured custom field values in the batch" do
    custom_field = Fabricate(:user_field, name: "Role")
    user.custom_fields["user_field_#{custom_field.id}"] = "Engineer"
    user.save_custom_fields
    user.user_stat.update!(posts_read_count: 15)
    other_user.custom_fields["user_field_#{custom_field.id}"] = "Designer"
    other_user.save_custom_fields
    other_user.user_stat.update!(posts_read_count: 30)
    configuration["mappings"].concat(
      [
        { "source" => "posts_read", "destination" => "Posts_Read__c", "policy" => "overwrite" },
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
        { name: "Posts_Read__c", type: "double", createable: true, updateable: true },
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
      sent["records"].map { |record| record.slice("Email", "Posts_Read__c", "Role__c") },
    ).to eq(
      [
        { "Email" => user.email, "Posts_Read__c" => 15, "Role__c" => "Engineer" },
        { "Email" => other_user.email, "Posts_Read__c" => 30, "Role__c" => "Designer" },
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
    failed_link =
      Salesforce::RecordLink.new(
        provider: "salesforce",
        account: instance_url,
        object: "Contact",
        user_id: other_user.id,
      )
    expect(failed_link.read["id"]).to eq("contact2")
    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] }).to eq(
      [other_user.id],
    )
  end

  it "defers ambiguous matches and missing linked records to individual jobs" do
    Salesforce::RecordLink.new(
      provider: "salesforce",
      account: instance_url,
      object: "Contact",
      user_id: other_user.id,
    ).write("missing")
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

  it "reconciles linked converted Leads without retrying or recreating them" do
    configuration["object"] = "Lead"
    configuration["mappings"] = [
      { "source" => "last", "destination" => "LastName", "policy" => "keep" },
      {
        "source" => "static",
        "value" => "Unknown",
        "destination" => "Company",
        "policy" => "overwrite",
      },
    ]
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    lead_fields =
      %w[Email LastName Company].map do |name|
        { name: name, type: "string", createable: true, updateable: true }
      end
    stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: lead_fields }.to_json)
    lead_id = "00Qbm00000v6wJpEAI"
    Salesforce::RecordLink.new(
      provider: "salesforce",
      account: instance_url,
      object: "Lead",
      user_id: user.id,
    ).write(lead_id)
    query =
      stub_request(:get, query_path).with(
        query: hash_including("q" => /Email IN .* OR Id IN \('#{lead_id}'\)/),
      ).to_return(
        body: {
          records: [
            {
              Id: lead_id,
              Email: user.email,
              LastName: "Morgan",
              Company: "Unknown",
              IsConverted: true,
              ConvertedContactId: "contact-123",
            },
            {
              Id: "lead-converted-other",
              Email: other_user.email,
              IsConverted: true,
              ConvertedContactId: "contact-other",
            },
          ],
        }.to_json,
      )

    run_batch

    expect(query).to have_been_requested.once
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(a_request(:patch, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
    expect(user.reload.salesforce_lead_id).to be_nil
    expect(user.salesforce_contact_id).to eq("contact-123")
    expect(other_user.reload.salesforce_lead_id).to be_nil
    expect(other_user.salesforce_contact_id).to eq("contact-other")
    expect(
      Salesforce::RecordLink.new(
        provider: "salesforce",
        account: instance_url,
        object: "Lead",
        user_id: user.id,
      ).read,
    ).to include("converted_to" => { "object" => "Contact", "id" => "contact-123" })
  end

  it "skips Lead batches with only already-converted users without contacting Salesforce" do
    configuration["object"] = "Lead"
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    [user, other_user].each do |member|
      Salesforce::RecordLink.new(
        provider: "salesforce",
        account: instance_url,
        object: "Lead",
        user_id: member.id,
      ).mark_converted_to("contact-#{member.id}")
    end

    run_batch

    expect(a_request(:get, %r{/sobjects/Lead/describe})).not_to have_been_made
    expect(a_request(:get, query_path)).not_to have_been_made
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(a_request(:patch, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
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
    Salesforce::RecordLink.new(
      provider: "salesforce",
      account: instance_url,
      object: "Contact",
      user_id: user.id,
    ).write("contact1")
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

  it "reconciles individual users after an uncertain collection write without recreating committed records" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    collection = stub_request(:post, collection_url).to_raise(Faraday::TimeoutError)

    run_batch

    retries = Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first }
    expect(retries.map { |args| args["user_id"] }).to contain_exactly(user.id, other_user.id)
    expect(retries).to all(include("configuration_id" => "batch", "reason" => "backfill"))
    status = PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:batch")
    expect(status["user_errors"].keys).to contain_exactly(user.id.to_s, other_user.id.to_s)
    expect(status["batch_error"]).to be_nil

    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %w[LastName LeadSource],
      record: {
        Id: "committed",
        LastName: "Morgan",
        LeadSource: "Discourse",
      },
    )
    stub_salesforce_person_lookup(
      "Contact",
      other_user.email,
      fields: %w[LastName LeadSource],
      records: [],
    )
    create =
      stub_request(:post, "#{api_path}/Contact").with(
        body: {
          Email: other_user.email,
          LastName: "Chen",
          LeadSource: "Discourse",
        },
      ).to_return(status: 201, body: { id: "new-contact" }.to_json)

    retries.each { |args| Jobs::SyncSalesforceUser.new.execute(args.deep_symbolize_keys) }

    expect(user.reload.salesforce_contact_id).to eq("committed")
    expect(other_user.reload.salesforce_contact_id).to eq("new-contact")
    expect(collection).to have_been_requested.once
    expect(create).to have_been_requested.once
    expect(Salesforce::GuidedSyncConfiguration.status_for(configuration)["error"]).to be_nil
  end

  ["not JSON", { unexpected: "response" }.to_json].each do |response_body|
    it "queues individual recovery for an uncertain response #{response_body.inspect}" do
      stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
        body: { records: [] }.to_json,
      )
      stub_request(:post, collection_url).to_return(status: 200, body: response_body)

      run_batch

      expect(
        Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] },
      ).to contain_exactly(user.id, other_user.id)
    end
  end

  it "only queues affected updates when creation succeeded before a server failure" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [{ Id: "existing", Email: other_user.email, LastName: "Chen", LeadSource: nil }],
      }.to_json,
    )
    created =
      stub_request(:post, collection_url).to_return(
        status: 200,
        body: [{ id: "created", success: true }].to_json,
      )
    stub_request(:patch, collection_url).to_return(status: 503, body: "Unavailable")

    run_batch

    expect(user.reload.salesforce_contact_id).to eq("created")
    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] }).to eq(
      [other_user.id],
    )
    expect(created).to have_been_requested.once
  end

  it "queues individual recovery after a connection failure during a write" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    stub_request(:post, collection_url).to_raise(Faraday::ConnectionFailed)

    run_batch

    expect(
      Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] },
    ).to contain_exactly(user.id, other_user.id)
  end

  it "keeps authentication, permission and rate-limit write failures on the batch retry path" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    [401, 403, 429].each do |status|
      stub_request(:post, collection_url).to_return(status: status, body: "Rejected")

      expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse) { |error|
        expect(error.status).to eq(status)
      }
      expect(Jobs::SyncSalesforceUser.jobs).to be_empty
    end
  end

  it "records lookup failures and raises for Sidekiq to retry the batch" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      status: 503,
      body: "Unavailable",
    )

    expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse)
    status = PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:batch")
    expect(status).to include(
      "batch_error" => hash_including("error" => "Salesforce::InvalidApiResponse"),
    )
    expect(status["user_errors"]).to be_empty
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
    expect(a_request(:post, collection_url)).not_to have_been_made
  end
end
