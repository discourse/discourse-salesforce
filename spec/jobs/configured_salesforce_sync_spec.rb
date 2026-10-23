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
    SiteSetting.enable_salesforce_configurations = true
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

  it "enqueues profile changes only when enabled" do
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
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
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
    SiteSetting.enable_salesforce_configurations = false
    run_sync
    SiteSetting.enable_salesforce_configurations = true
    PluginStore.set(Salesforce::PLUGIN_NAME, Salesforce::GuidedSyncConfiguration::STORE_KEY, [])
    run_sync
    expect(a_request(:get, %r{/sobjects/})).not_to have_been_made
  end

  it "does not run legacy demos or disabled triggers" do
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
    run_sync("join")
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
    Jobs::SyncSalesforceConfiguration.new.execute(configuration_id: "sync", reason: "backfill")
    expect(
      Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] },
    ).to contain_exactly(user.id, newcomer.id)
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
