# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::GuidedSyncConfiguration do
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
end
