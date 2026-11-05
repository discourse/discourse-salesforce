# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::ConfigurationScheduler do
  before do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
    SiteSetting.salesforce_instance_url = "https://current.salesforce.com"
  end

  it "enqueues weekly and hourly configurations once per interval and skips manual schedules" do
    configurations =
      %w[weekly hourly manual].to_h do |schedule|
        [schedule, Fabricate(:guided_sync_configuration, schedule: schedule)]
      end
    freeze_time Time.utc(2026, 10, 26, 2)
    Jobs::SyncSalesforceConfiguration.clear
    2.times { described_class.enqueue_due }
    expect(
      Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first["configuration_id"] },
    ).to contain_exactly(configurations["weekly"].id, configurations["hourly"].id)
    Jobs::SyncSalesforceConfiguration.clear
    freeze_time 1.hour.from_now
    described_class.enqueue_due
    expect(
      Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first["configuration_id"] },
    ).to eq([configurations["hourly"].id])
    Jobs::SyncSalesforceConfiguration.clear
    freeze_time Time.utc(2026, 11, 2, 2)
    described_class.enqueue_due
    expect(
      Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first["configuration_id"] },
    ).to contain_exactly(configurations["weekly"].id, configurations["hourly"].id)
  end

  it "resets scheduling and backfills when explicitly saved for a different connection" do
    configuration =
      Fabricate(
        :guided_sync_configuration,
        account: "https://previous.salesforce.com",
        last_scheduled_at: 1.day.ago,
      )
    Jobs::SyncSalesforceConfiguration.clear
    freeze_time
    configuration.update!(account: SiteSetting.salesforce_instance_url)

    described_class.configuration_saved(configuration, group_ids_changed: false)

    expect(configuration.reload.last_scheduled_at).to eq_time(Time.zone.now)
    expect(
      Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first },
    ).to contain_exactly(
      hash_including("configuration_id" => configuration.id, "reason" => "backfill"),
    )
  end

  it "enqueues member changes only for configurations scoped to the user's groups" do
    group = Fabricate(:group)
    other_group = Fabricate(:group)
    user = Fabricate(:user)
    group.add(user)
    scoped = Fabricate(:guided_sync_configuration, groups: [group])
    Fabricate(:guided_sync_configuration, groups: [other_group])
    manual = Fabricate(:guided_sync_configuration, groups: [group], schedule: "manual")
    Jobs::SyncSalesforceUser.clear

    described_class.enqueue_user(user, reason: "change")
    described_class.enqueue_user(user, reason: "scheduled")

    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first }).to contain_exactly(
      hash_including("configuration_id" => scoped.id, "reason" => "change"),
      hash_including("configuration_id" => manual.id, "reason" => "change"),
      hash_including("configuration_id" => scoped.id, "reason" => "scheduled"),
    )
  end
end
