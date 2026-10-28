# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::ConfigurationScheduler do
  before do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
  end

  it "enqueues weekly and hourly configurations once per interval and skips manual schedules" do
    records =
      %w[weekly hourly manual].map do |schedule|
        { "id" => schedule, "active" => true, "kind" => "users", "schedule" => schedule }
      end
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      Salesforce::GuidedSyncConfiguration::STORE_KEY,
      records,
    )
    freeze_time Time.utc(2026, 10, 26, 2)
    Jobs::SyncSalesforceConfiguration.clear
    2.times { described_class.enqueue_due }
    expect(
      Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first["configuration_id"] },
    ).to contain_exactly("weekly", "hourly")
    Jobs::SyncSalesforceConfiguration.clear
    freeze_time 1.hour.from_now
    described_class.enqueue_due
    expect(
      Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first["configuration_id"] },
    ).to eq(["hourly"])
    Jobs::SyncSalesforceConfiguration.clear
    freeze_time Time.utc(2026, 11, 2, 2)
    described_class.enqueue_due
    expect(
      Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first["configuration_id"] },
    ).to contain_exactly("weekly", "hourly")
  end
end
