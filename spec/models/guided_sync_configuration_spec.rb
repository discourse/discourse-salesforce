# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::GuidedSyncConfiguration do
  fab!(:group)
  fab!(:user) { Fabricate(:user, active: true) }
  fab!(:other_user) { Fabricate(:user, active: true) }

  it "selects current-account configurations without querying group display names" do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
    SiteSetting.salesforce_instance_url = "https://current.salesforce.com"
    current = {
      "id" => "current",
      "kind" => "users",
      "active" => true,
      "provider" => "salesforce",
      "instance_url" => SiteSetting.salesforce_instance_url,
      "group_ids" => [group.id],
    }
    records = [
      current,
      current.merge("id" => "stale", "instance_url" => "https://previous.salesforce.com"),
      current.merge("id" => "other", "provider" => "hubspot"),
    ]
    PluginStore.set(Salesforce::PLUGIN_NAME, described_class::STORE_KEY, records)

    active = nil
    queries = track_sql_queries { active = described_class.active }

    expect(active).to eq([current])
    expect(queries.grep(/FROM "groups"/)).to be_empty
    displayed = nil
    queries = track_sql_queries { displayed = described_class.all }
    expect(queries.grep(/FROM "groups"/).size).to eq(1)
    expect(displayed.map { |record| record["groups"] }).to eq(
      [[group.name], [group.name], [group.name]],
    )
    expect(displayed.find { |record| record["id"] == "stale" }["connection_changed"]).to eq(true)
    expect(displayed.first).not_to have_key("connection_changed")
  end

  it "rejects unsupported providers before contacting Salesforce" do
    expect {
      described_class.save!({ provider: "hubspot" }, id: nil, guardian: Fabricate(:admin).guardian)
    }.to raise_error(Discourse::InvalidParameters, /provider/)
  end

  it "keeps unresolved user errors when another user syncs successfully" do
    group.add(user)
    group.add(other_user)
    configuration = { "id" => "sync", "group_ids" => [group.id] }

    described_class.record_result("sync", user.id, error: Salesforce::InvalidApiResponse.new)
    described_class.record_result("sync", other_user.id)

    expect(described_class.status_for(configuration)["error"]).to eq(
      "Salesforce::InvalidApiResponse",
    )
    expect(
      PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:sync")["user_errors"].keys,
    ).to contain_exactly(user.id.to_s)
  end

  it "clears user errors when they are no longer eligible members" do
    group.add(user)
    configuration = { "id" => "sync", "group_ids" => [group.id] }
    described_class.record_result("sync", user.id, error: Salesforce::InvalidApiResponse.new)

    group.remove(user)

    expect(described_class.status_for(configuration)).not_to have_key("error")
    expect(
      PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:sync")["user_errors"],
    ).to be_empty
  end

  it "stores batch errors separately from user errors and clears them on batch success" do
    described_class.record_result("sync", error: Salesforce::InvalidApiResponse.new)

    expect(PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_status:sync")).to include(
      "batch_error" => hash_including("error" => "Salesforce::InvalidApiResponse"),
    )

    described_class.record_batch_success("sync")

    expect(described_class.status_for("id" => "sync")).not_to have_key("error")
  end
end
