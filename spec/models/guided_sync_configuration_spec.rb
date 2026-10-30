# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::GuidedSyncConfiguration do
  fab!(:group)
  fab!(:user) { Fabricate(:user, active: true) }
  fab!(:other_user) { Fabricate(:user, active: true) }

  it "defaults existing configurations to Salesforce and only activates Salesforce configurations" do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
    records = [
      { "id" => "legacy", "kind" => "users", "active" => true },
      { "id" => "other", "kind" => "users", "active" => true, "provider" => "hubspot" },
    ]
    PluginStore.set(Salesforce::PLUGIN_NAME, described_class::STORE_KEY, records)
    expect(described_class.all.first["provider"]).to eq("salesforce")
    expect(described_class.active.map { |record| record["id"] }).to eq(["legacy"])
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
