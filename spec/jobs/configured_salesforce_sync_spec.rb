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
      "active" => true,
      "group_id" => group.id,
      "group" => group.name,
      "object" => "Lead",
      "instance_url" => instance_url,
      "onJoin" => true,
      "onChange" => true,
      "backfill" => true,
      "schedule" => "daily",
      "mappings" => [
        { "source" => "last", "destination" => "LastName", "policy" => "keep" },
        { "source" => "company", "destination" => "Company", "policy" => "keep" },
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
    group.add(user)
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: fields }.to_json)
  end

  def run_sync(reason = "backfill")
    Jobs::SyncSalesforceUser.new.execute(configuration_id: "sync", user_id: user.id, reason: reason)
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
          Company: "None",
          Trust__c: user.trust_level,
        },
      ).to_return(status: 201, body: { id: "lead123" }.to_json)
    run_sync
    expect(user.reload.salesforce_lead_id).to eq("lead123")
    stub_request(:get, "#{api_path}/Lead/lead123").to_return(
      body: {
        Id: "lead123",
        LastName: "Morgan",
        Company: "None",
        Trust__c: user.trust_level,
      }.to_json,
    )
    user.primary_email.update!(email: "new-address@example.com")
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
          Company: "None",
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
        Company: "None",
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
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      "configured_user_link:Lead:#{user.id}",
      { id: old_id, instance: instance_url },
    )
    stub_request(:get, "#{api_path}/Lead/#{old_id}").to_return(status: 404, body: "[]")
    query = "SELECT Id, IsDeleted, IsConverted FROM Lead WHERE Id = '#{old_id}'"
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
        Company: "None",
        Trust__c: user.trust_level,
      }.to_json,
    )
    run_sync
    expect(create).to have_been_requested.once
  end

  it "does not recreate inaccessible or converted Leads" do
    old_id = "00Qbm00000v6wJpEAI"
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      "configured_user_link:Lead:#{user.id}",
      { id: old_id, instance: instance_url },
    )
    stub_request(:get, "#{api_path}/Lead/#{old_id}").to_return(status: 404, body: "[]")
    query = "SELECT Id, IsDeleted, IsConverted FROM Lead WHERE Id = '#{old_id}'"
    [[], [{ Id: old_id, IsDeleted: true, IsConverted: true }]].each do |records|
      stub_request(:get, "#{instance_url}services/data/v49.0/queryAll/").with(
        query: {
          q: query,
        },
      ).to_return(body: { records: records }.to_json)
      expect { run_sync }.to raise_error(Salesforce::InvalidApiResponse)
    end
    expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
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
    expect(
      PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:sync")["error"],
    ).to be_present
    stub_request(:get, "#{api_path}/Lead/lead123").to_return(
      body: { Id: "lead123", LastName: "CRM name", Company: "Company", Trust__c: 99 }.to_json,
    )
    run_sync
    expect(PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:sync")).not_to have_key(
      "error",
    )
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

  it "always enqueues profile changes even for old configurations with the trigger disabled" do
    Jobs::SyncSalesforceUser.clear
    DiscourseEvent.trigger(:user_updated, user, ["name"])
    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first }).to include(
      hash_including("user_id" => user.id, "configuration_id" => "sync", "reason" => "change"),
    )
    configuration["onChange"] = false
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      [configuration],
    )
    Jobs::SyncSalesforceUser.clear
    DiscourseEvent.trigger(:user_updated, user, ["name"])
    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first }).to include(
      hash_including("user_id" => user.id, "configuration_id" => "sync", "reason" => "change"),
    )
  end

  it "skips unchanged profile requests but retries failures and refreshes scheduled syncs" do
    record = { Id: "lead123", LastName: "Morgan", Company: "None", Trust__c: user.trust_level }
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
        body: { Company: "None", Trust__c: user.trust_level }.to_json,
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
    expect(PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:sync")["error"]).to eq(
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
    configuration.merge!("active" => true, "backfill" => false, "onJoin" => false)
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
    configuration.merge!(
      "group_ids" => [group.id, second_group.id],
      "groups" => [group.name, second_group.name],
    )
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

    group.remove(user)
    instance = instance_double(Salesforce::ConfiguredUserSync, sync: nil)
    allow(Salesforce::ConfiguredUserSync).to receive(:new).and_return(instance)
    run_sync("change")
    expect(instance).to have_received(:sync).once
    second_group.remove(user)
    run_sync("change")
    expect(instance).to have_received(:sync).once
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
