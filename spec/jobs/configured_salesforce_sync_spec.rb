# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::SyncSalesforceUser do
  include_context "with salesforce spec helper"

  fab!(:user) { Fabricate(:user, name: "Alex Morgan", active: true) }
  fab!(:group)
  let(:configuration) do
    {
      "id" => "sync",
      "kind" => "users",
      "provider" => "salesforce",
      "active" => true,
      "group_ids" => [group.id],
      "object" => "Lead",
      "instance_url" => instance_url,
      "backfill" => true,
      "schedule" => "daily",
      "mappings" => [
        { "source" => "last", "destination" => "LastName", "policy" => "keep" },
        {
          "source" => "static",
          "value" => "Unknown",
          "destination" => "Company",
          "policy" => "keep",
        },
        { "source" => "trust", "destination" => "Trust__c", "policy" => "overwrite" },
      ],
    }
  end
  let(:fields) do
    %w[Email LastName Company Trust__c].map do |name|
      {
        name: name,
        type: name == "Trust__c" ? "int" : "string",
        createable: true,
        updateable: true,
      }
    end
  end

  before do
    SiteSetting.enable_guided_sync_configuration = true
    user.activate
    group.add(user)
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: fields }.to_json)
    stub_request(:get, query_path).with(
      query: {
        q:
          "SELECT Id, IsConverted, ConvertedContactId FROM Lead WHERE Email = '#{user.email}' AND IsConverted = true",
      },
    ).to_return(body: { totalSize: 0, records: [] }.to_json)
  end

  def run_sync(reason = "backfill")
    Jobs::SyncSalesforceUser.new.execute(configuration_id: "sync", user_id: user.id, reason: reason)
  end

  it "skips active users whose current email is unconfirmed" do
    user.email_tokens.delete_all
    user.email_tokens.create!(email: user.email, scope: EmailToken.scopes[:signup])
    expect(user.reload).to be_active
    expect(user.email_confirmed?).to eq(false)

    run_sync

    expect(a_request(:get, query_path)).not_to have_been_made
    expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
    expect(user.reload.salesforce_lead_id).to be_nil
  end

  it "resumes skipped sync after an already-active member confirms their email" do
    user.email_tokens.delete_all
    token = Fabricate(:email_token, user: user)
    expect(user.reload).to be_active
    expect(user.email_confirmed?).to eq(false)
    run_sync
    expect(a_request(:get, query_path)).not_to have_been_made
    Jobs::SyncSalesforceUser.clear

    EmailToken.confirm(token.token, scope: EmailToken.scopes[:signup])

    jobs =
      Jobs::SyncSalesforceUser
        .jobs
        .map { |job| job["args"].first }
        .select { |args| args["configuration_id"] == "sync" }
    expect(jobs).to contain_exactly(hash_including("user_id" => user.id, "reason" => "change"))
    stub_salesforce_person_lookup("Lead", user.email, fields: %w[LastName Company Trust__c])
    create =
      stub_request(:post, "#{api_path}/Lead").to_return(
        status: 201,
        body: { id: "confirmed-lead" }.to_json,
      )

    Jobs::SyncSalesforceUser.new.execute(jobs.first.symbolize_keys)

    expect(create).to have_been_requested.once
    expect(user.reload.salesforce_lead_id).to eq("confirmed-lead")
  end

  it "creates a Lead and retains its link for idempotent retries and email changes" do
    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      records: [],
      fields: %w[LastName Company Trust__c],
    )
    create =
      stub_request(:post, "#{api_path}/Lead").with(
        body: {
          Email: user.email,
          LastName: "Morgan",
          Company: "Unknown",
          Trust__c: user.trust_level,
        },
      ).to_return(status: 201, body: { id: "lead123" }.to_json)
    run_sync
    expect(user.reload.salesforce_lead_id).to eq("lead123")
    stub_request(:get, "#{api_path}/Lead/lead123").to_return(
      body: {
        Id: "lead123",
        LastName: "Morgan",
        Company: "Unknown",
        Trust__c: user.trust_level,
      }.to_json,
    )
    user.primary_email.update!(email: "new-address@example.com")
    user.reload.activate
    run_sync
    expect(create).to have_been_requested.once
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "sends static text on creation and respects ownership on updates" do
    configuration["mappings"] << {
      "source" => "static",
      "destination" => "LeadSource",
      "policy" => "overwrite",
      "value" => "Discourse",
    }
    fields << { name: "LeadSource", type: "picklist", createable: true, updateable: true }
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: fields }.to_json)
    stub_request(:get, query_path).with(
      query: {
        q:
          "SELECT Id, IsConverted, ConvertedContactId FROM Lead WHERE Email = '#{user.email}' AND IsConverted = true",
      },
    ).to_return(body: { totalSize: 0, records: [] }.to_json)

    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      records: [],
      fields: %w[LastName Company Trust__c LeadSource],
    )
    create =
      stub_request(:post, "#{api_path}/Lead").with(
        body: {
          Email: user.email,
          LastName: "Morgan",
          Company: "Unknown",
          Trust__c: user.trust_level,
          LeadSource: "Discourse",
        },
      ).to_return(status: 201, body: { id: "lead123" }.to_json)
    run_sync
    expect(create).to have_been_requested.once
    stub_request(:get, "#{api_path}/Lead/lead123").to_return(
      body: {
        Id: "lead123",
        LastName: "Morgan",
        Company: "Unknown",
        Trust__c: user.trust_level,
        LeadSource: "Web",
      }.to_json,
    )
    update =
      stub_request(:patch, "#{api_path}/Lead/lead123").with(
        body: {
          LeadSource: "Discourse",
        },
      ).to_return(status: 204)
    run_sync
    configuration["mappings"].last["policy"] = "keep"
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    run_sync
    expect(update).to have_been_requested.once
  end

  it "recreates a confirmed deleted Lead and relinks subsequent retries" do
    old_id = "00Qbm00000v6wJpEAI"
    Salesforce::RecordLink.new(
      provider: "salesforce",
      account: instance_url,
      object: "Lead",
      user_id: user.id,
    ).write(old_id)
    stub_request(:get, "#{api_path}/Lead/#{old_id}").to_return(status: 404, body: "[]")
    query = "SELECT Id, IsDeleted, IsConverted, ConvertedContactId FROM Lead WHERE Id = '#{old_id}'"
    stub_request(:get, "#{instance_url}services/data/v49.0/queryAll/").with(
      query: {
        q: query,
      },
    ).to_return(body: { records: [{ Id: old_id, IsDeleted: true, IsConverted: false }] }.to_json)
    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      records: [],
      fields: %w[LastName Company Trust__c],
    )
    create =
      stub_request(:post, "#{api_path}/Lead").to_return(
        status: 201,
        body: { id: "newlead" }.to_json,
      )
    run_sync
    expect(user.reload.salesforce_lead_id).to eq("newlead")
    stub_request(:get, "#{api_path}/Lead/newlead").to_return(
      body: {
        Id: "newlead",
        LastName: "Morgan",
        Company: "Unknown",
        Trust__c: user.trust_level,
      }.to_json,
    )
    run_sync
    expect(create).to have_been_requested.once
  end

  it "does not recreate inaccessible or converted Leads" do
    old_id = "00Qbm00000v6wJpEAI"
    Salesforce::RecordLink.new(
      provider: "salesforce",
      account: instance_url,
      object: "Lead",
      user_id: user.id,
    ).write(old_id)
    stub_request(:get, "#{api_path}/Lead/#{old_id}").to_return(status: 404, body: "[]")
    query = "SELECT Id, IsDeleted, IsConverted, ConvertedContactId FROM Lead WHERE Id = '#{old_id}'"
    lookup =
      stub_request(:get, "#{instance_url}services/data/v49.0/queryAll/")
        .with(query: { q: query })
        .to_return(body: { records: [] }.to_json)
        .then
        .to_return(
          body: {
            records: [
              { Id: old_id, IsDeleted: true, IsConverted: true, ConvertedContactId: "contact-123" },
            ],
          }.to_json,
        )
    expect { run_sync }.to raise_error(Salesforce::InvalidApiResponse)
    expect { run_sync }.not_to raise_error
    expect(lookup).to have_been_requested.twice
    expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
  end

  it "retires a linked converted Lead and skips future syncs without creating a replacement" do
    lead_id = "00Qbm00000v6wJpEAI"
    lead_link =
      Salesforce::RecordLink.new(
        provider: "salesforce",
        account: instance_url,
        object: "Lead",
        user_id: user.id,
      )
    contact_link =
      Salesforce::RecordLink.new(
        provider: "salesforce",
        account: instance_url,
        object: "Contact",
        user_id: user.id,
      )
    lead_link.write(lead_id)
    linked_lead =
      stub_request(:get, "#{api_path}/Lead/#{lead_id}").to_return(
        body: { Id: lead_id, IsConverted: true, ConvertedContactId: "contact-123" }.to_json,
      )

    run_sync
    run_sync

    expect(linked_lead).to have_been_requested.once
    expect(lead_link.read).to include(
      "converted_to" => {
        "object" => "Contact",
        "id" => "contact-123",
      },
    )
    expect(contact_link.read).to include("id" => "contact-123")
    expect(user.reload.salesforce_lead_id).to be_nil
    expect(user.salesforce_contact_id).to eq("contact-123")
    expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    expect(a_request(:patch, %r{/sobjects/Lead/})).not_to have_been_made
  end

  it "reconciles a converted Lead found by email instead of creating a replacement" do
    stub_salesforce_person_lookup("Lead", user.email, fields: %w[LastName Company Trust__c])
    stub_request(:get, query_path).with(
      query: {
        q:
          "SELECT Id, IsConverted, ConvertedContactId FROM Lead WHERE Email = '#{user.email}' AND IsConverted = true",
      },
    ).to_return(
      body: {
        totalSize: 1,
        records: [
          { Id: "00Qbm00000v6wJpEAI", IsConverted: true, ConvertedContactId: "contact-456" },
        ],
      }.to_json,
    )

    run_sync

    expect(user.reload.salesforce_lead_id).to be_nil
    expect(user.salesforce_contact_id).to eq("contact-456")
    expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    expect(
      Salesforce::RecordLink.new(
        provider: "salesforce",
        account: instance_url,
        object: "Lead",
        user_id: user.id,
      ).read,
    ).to include("converted_to" => { "object" => "Contact", "id" => "contact-456" })
  end

  it "creates Contacts independently from Leads" do
    configuration["object"] = "Contact"
    configuration["mappings"] = [
      { "source" => "last", "destination" => "LastName", "policy" => "keep" },
    ]
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    stub_request(:get, "#{api_path}/Contact/describe").to_return(body: { fields: fields }.to_json)
    stub_salesforce_person_lookup("Contact", user.email, records: [], fields: %w[LastName])
    create =
      stub_request(:post, "#{api_path}/Contact").with(
        body: {
          Email: user.email,
          LastName: "Morgan",
        },
      ).to_return(status: 201, body: { id: "contact123" }.to_json)
    run_sync
    expect(create).to have_been_requested.once
    expect(user.reload.salesforce_contact_id).to eq("contact123")
    expect(user.salesforce_lead_id).to be_nil
  end

  it "propagates transient failures for retry and clears the affected user's error after success" do
    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      record: {
        Id: "lead123",
        LastName: "CRM name",
        Company: "Company",
        Trust__c: 99,
      },
      fields: %w[LastName Company Trust__c],
    )
    stub_request(:patch, "#{api_path}/Lead/lead123")
      .to_return(status: 503)
      .then
      .to_return(status: 204)
    expect { run_sync }.to raise_error(Salesforce::InvalidApiResponse)
    expect(Salesforce::GuidedSyncConfiguration.status_for(configuration)["error"]).to be_present
    stub_request(:get, "#{api_path}/Lead/lead123").to_return(
      body: { Id: "lead123", LastName: "CRM name", Company: "Company", Trust__c: 99 }.to_json,
    )
    run_sync
    expect(Salesforce::GuidedSyncConfiguration.status_for(configuration)).not_to have_key("error")
  end

  it "rejects unsupported mappings and changed Salesforce instances before writing" do
    configuration["mappings"].first["destination"] = "LastName FROM Contact"
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    expect { run_sync }.to raise_error(Discourse::InvalidParameters)
    configuration["instance_url"] = "https://other.my.salesforce.com"
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    expect { run_sync }.to raise_error(Discourse::InvalidParameters)
    expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "uses real rolling post counts and excludes old and private-message posts" do
    Fabricate(:post, user: user, created_at: 31.days.ago)
    Fabricate(:post, user: user, created_at: 2.days.ago)
    Fabricate(:post, user: user, topic: Fabricate(:private_message_topic, user: user))
    configuration["mappings"] << {
      "source" => "posts30",
      "destination" => "Posts30__c",
      "policy" => "overwrite",
    }
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    fields << { name: "Posts30__c", type: "int", createable: true, updateable: true }
    stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: fields }.to_json)
    stub_request(:get, query_path).with(
      query: {
        q:
          "SELECT Id, IsConverted, ConvertedContactId FROM Lead WHERE Email = '#{user.email}' AND IsConverted = true",
      },
    ).to_return(body: { totalSize: 0, records: [] }.to_json)

    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      record: {
        Id: "lead123",
        LastName: "CRM",
        Company: "CRM",
        Trust__c: user.trust_level,
        Posts30__c: 100,
      },
      fields: %w[LastName Company Trust__c Posts30__c],
    )
    update =
      stub_request(:patch, "#{api_path}/Lead/lead123").with(body: { Posts30__c: 1 }).to_return(
        status: 204,
      )
    run_sync("scheduled")
    expect(update).to have_been_requested.once
  end

  it "enqueues profile changes for matching configurations" do
    Jobs::SyncSalesforceUser.clear
    DiscourseEvent.trigger(:user_updated, user, ["name"])
    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first }).to include(
      hash_including("user_id" => user.id, "configuration_id" => "sync", "reason" => "change"),
    )
  end

  it "skips unchanged profile requests but retries failures and refreshes scheduled syncs" do
    record = { Id: "lead123", LastName: "Morgan", Company: "Unknown", Trust__c: user.trust_level }
    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      record: record,
      fields: %w[LastName Company Trust__c],
    )
    linked = stub_request(:get, "#{api_path}/Lead/lead123").to_return(body: record.to_json)
    run_sync("change")
    run_sync("change")
    user.update_columns(locale: "fr")
    run_sync("change")
    expect(linked).not_to have_been_requested

    user.update_columns(trust_level: user.trust_level + 1)
    update =
      stub_request(:patch, "#{api_path}/Lead/lead123")
        .to_return(status: 503, body: "unavailable")
        .then
        .to_return(status: 204)
    expect { run_sync("change") }.to raise_error(Salesforce::InvalidApiResponse)
    run_sync("change")
    expect(update).to have_been_requested.twice
    run_sync("change")
    expect(linked).to have_been_requested.twice
    run_sync("scheduled")
    expect(linked).to have_been_requested.times(3)
  end

  it "preserves nonempty Salesforce values, fills blanks, and overwrites selected fields" do
    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      record: {
        Id: "lead123",
        LastName: "CRM name",
        Company: "",
        Trust__c: 99,
      },
      fields: %w[LastName Company Trust__c],
    )
    update =
      stub_request(:patch, "#{api_path}/Lead/lead123").with(
        body: { Company: "Unknown", Trust__c: user.trust_level }.to_json,
      ).to_return(status: 204)
    run_sync
    expect(update).to have_been_requested.once
    expect(
      PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:sync")["last_synced_at"],
    ).to be_present
  end

  it "rejects ambiguous matches without writing and records a failure" do
    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      records: [{ Id: "one" }, { Id: "two" }],
      fields: %w[LastName Company Trust__c],
    )
    expect { run_sync }.to raise_error(Salesforce::AmbiguousEmailMatch)
    expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
    expect(Salesforce::GuidedSyncConfiguration.status_for(configuration)["error"]).to eq(
      "Salesforce::AmbiguousEmailMatch",
    )
  end

  it "does not write for removed members, deleted configurations, or disabled features" do
    group.remove(user)
    run_sync
    group.add(user)
    SiteSetting.enable_guided_sync_configuration = false
    run_sync
    SiteSetting.enable_guided_sync_configuration = true
    PluginStore.set(Salesforce::PLUGIN_NAME, Salesforce::GuidedSyncConfiguration::STORE_KEY, [])
    run_sync
    expect(a_request(:get, %r{/sobjects/})).not_to have_been_made
  end

  it "does not run inactive configurations or disabled backfills" do
    configuration["active"] = false
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    run_sync
    configuration.merge!("active" => true, "backfill" => false)
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    run_sync
    expect(a_request(:get, %r{/sobjects/})).not_to have_been_made
  end

  it "enqueues group membership work and backfills only eligible current members" do
    Jobs::SyncSalesforceUser.clear
    newcomer = Fabricate(:user)
    group.add(newcomer)
    expect(
      Jobs::SyncSalesforceUser
        .jobs
        .map { |job| job["args"].first }
        .select { |args| args["configuration_id"] == "sync" },
    ).to include(hash_including("user_id" => newcomer.id, "reason" => "join"))
    group.add(Fabricate(:user, active: false))
    group.add(Discourse.system_user)
    Jobs::SyncSalesforceUser.clear
    Jobs::SyncSalesforceUserBatch.clear
    Jobs::SyncSalesforceConfiguration.new.execute(configuration_id: "sync", reason: "backfill")
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
    expect(
      Jobs::SyncSalesforceUserBatch.jobs.flat_map { |job| job["args"].first["user_ids"] },
    ).to contain_exactly(user.id, newcomer.id)
  end

  it "limits scheduled refreshes to members with a linked Salesforce record" do
    existing = Fabricate(:user)
    group.add(existing)
    Salesforce::RecordLink.new(
      provider: "salesforce",
      account: instance_url,
      object: "Lead",
      user_id: existing.id,
    ).write("lead-existing")
    Jobs::SyncSalesforceUserBatch.clear

    Jobs::SyncSalesforceConfiguration.new.execute(configuration_id: "sync", reason: "scheduled")

    expect(
      Jobs::SyncSalesforceUserBatch.jobs.flat_map { |job| job["args"].first["user_ids"] },
    ).to contain_exactly(existing.id)
  end

  it "syncs the union of groups once and continues syncing members of another selected group" do
    second_group = Fabricate(:group)
    newcomer = Fabricate(:user)
    configuration.merge!("group_ids" => [group.id, second_group.id])
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    second_group.add(user)
    Jobs::SyncSalesforceUser.clear
    second_group.add(newcomer)
    jobs =
      Jobs::SyncSalesforceUser
        .jobs
        .map { |job| job["args"].first }
        .select { |args| args["configuration_id"] == "sync" }
    expect(jobs).to contain_exactly(hash_including("user_id" => newcomer.id, "reason" => "join"))

    Jobs::SyncSalesforceUserBatch.clear
    Jobs::SyncSalesforceConfiguration.new.execute(configuration_id: "sync", reason: "backfill")
    expect(
      Jobs::SyncSalesforceUserBatch.jobs.flat_map { |job| job["args"].first["user_ids"] },
    ).to contain_exactly(user.id, newcomer.id)

    lookup =
      stub_salesforce_person_lookup(
        "Lead",
        user.email,
        record: {
          Id: "scoped-lead",
          LastName: "CRM",
          Company: "CRM",
          Trust__c: 0,
        },
        fields: %w[LastName Company Trust__c],
      )
    update =
      stub_request(:patch, "#{api_path}/Lead/scoped-lead").with(
        body: {
          Trust__c: user.trust_level,
        },
      ).to_return(status: 204)
    linked_record =
      stub_request(:get, "#{api_path}/Lead/scoped-lead").to_return(
        body: { Id: "scoped-lead", LastName: "CRM", Company: "CRM", Trust__c: 0 }.to_json,
      )

    group.remove(user)
    run_sync("change")
    expect(user.reload.salesforce_lead_id).to eq("scoped-lead")
    expect(update).to have_been_requested.once

    second_group.remove(user)
    user.update_columns(trust_level: user.trust_level + 1)
    run_sync("change")

    expect(lookup).to have_been_requested.once
    expect(update).to have_been_requested.once
    expect(linked_record).not_to have_been_requested
  end

  it "schedules a daily refresh once after 02:00 UTC" do
    freeze_time Time.utc(2026, 10, 23, 1)
    Jobs::SyncSalesforceConfiguration.clear
    Jobs::SyncSalesforceConfigurations.new.execute({})
    expect(Jobs::SyncSalesforceConfiguration.jobs).to be_empty
    freeze_time Time.utc(2026, 10, 23, 2)
    2.times { Jobs::SyncSalesforceConfigurations.new.execute({}) }
    expect(Jobs::SyncSalesforceConfiguration.jobs.size).to eq(1)
  end
end
