# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::ConfigurationScheduler do
  before do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
    SiteSetting.salesforce_instance_url = "https://current.salesforce.com"
  end

  it "enqueues weekly and hourly configurations once per interval and skips manual schedules" do
    records =
      %w[weekly hourly manual].map do |schedule|
        {
          "id" => schedule,
          "active" => true,
          "kind" => "users",
          "schedule" => schedule,
          "provider" => "salesforce",
          "instance_url" => SiteSetting.salesforce_instance_url,
        }
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

  it "resets scheduling and backfills when explicitly saved for a different connection" do
    previous = {
      "id" => "sync",
      "active" => true,
      "backfill" => true,
      "schedule" => "daily",
      "group_ids" => [],
      "instance_url" => "https://previous.salesforce.com",
    }
    record = previous.merge("instance_url" => SiteSetting.salesforce_instance_url)
    Jobs::SyncSalesforceConfiguration.clear
    freeze_time
    PluginStore.set(Salesforce::PLUGIN_NAME, "configuration_scheduled_at:sync", 1.day.ago.to_i)

    described_class.configuration_saved(record, previous: previous)

    expect(PluginStore.get(Salesforce::PLUGIN_NAME, "configuration_scheduled_at:sync")).to eq(
      Time.now.to_i,
    )
    expect(
      Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first },
    ).to contain_exactly(hash_including("configuration_id" => "sync", "reason" => "backfill"))
  end
end
