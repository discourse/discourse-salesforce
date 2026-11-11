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
        [schedule, Fabricate(:sync_configuration, schedule: schedule)]
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
        :sync_configuration,
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
    scoped = Fabricate(:sync_configuration, groups: [group])
    Fabricate(:sync_configuration, groups: [other_group])
    manual = Fabricate(:sync_configuration, groups: [group], schedule: "manual")
    Jobs::SyncSalesforceUser.clear

    described_class.enqueue_user(user, reason: "change", inbound: true)
    described_class.enqueue_user(user, reason: "scheduled", inbound: true)

    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first }).to contain_exactly(
      hash_including("configuration_id" => scoped.id, "reason" => "change"),
      hash_including("configuration_id" => manual.id, "reason" => "change"),
      hash_including("configuration_id" => scoped.id, "reason" => "scheduled"),
    )
  end

  context "with hubspot configurations" do
    include_context "with hubspot spec helper"

    let!(:hubspot) { Fabricate(:hubspot_sync_configuration, schedule: "hourly") }

    it "dispatches scheduled and backfill runs to the provider's job" do
      freeze_time Time.utc(2026, 10, 26, 2)
      Jobs::SyncHubspotConfiguration.clear
      Jobs::SyncSalesforceConfiguration.clear

      described_class.enqueue_due
      described_class.configuration_saved(
        Fabricate(:hubspot_sync_configuration, account: "99999"),
        group_ids_changed: false,
      )

      expect(Jobs::SyncSalesforceConfiguration.jobs).to be_empty
      expect(
        Jobs::SyncHubspotConfiguration.jobs.map do |job|
          job["args"].first.slice("configuration_id", "reason")
        end,
      ).to contain_exactly(
        { "configuration_id" => hubspot.id, "reason" => "scheduled" },
        hash_including("reason" => "backfill"),
      )
    end

    it "enqueues user matching for every user change except group-driven ones" do
      user = Fabricate(:user)
      Jobs::SyncHubspotUser.clear
      Jobs::SyncSalesforceUser.clear

      described_class.enqueue_user(user, reason: "change", inbound: true)
      described_class.enqueue_user(user, reason: "join", inbound: true)
      described_class.enqueue_user(user, reason: "change", inbound: false)
      described_class.enqueue_user(
        user,
        reason: "join",
        group_id: Fabricate(:group).id,
        inbound: false,
      )

      expect(Jobs::SyncSalesforceUser.jobs).to be_empty
      expect(Jobs::SyncHubspotUser.jobs.map { |job| job["args"].first }).to contain_exactly(
        hash_including(
          "configuration_id" => hubspot.id,
          "user_id" => user.id,
          "reason" => "change",
        ),
        hash_including("configuration_id" => hubspot.id, "user_id" => user.id, "reason" => "join"),
      )
    end

    it "matches users on email changes and sign-ups but not on other profile or group changes" do
      user = Fabricate(:user)
      group = Fabricate(:group)
      Jobs::SyncHubspotUser.clear

      DiscourseEvent.trigger(:user_updated, user, %w[bio_raw])
      DiscourseEvent.trigger(:user_updated, user)
      DiscourseEvent.trigger(:user_added_to_group, user, group)
      DiscourseEvent.trigger(:user_removed_from_group, user, group)
      expect(Jobs::SyncHubspotUser.jobs).to be_empty

      DiscourseEvent.trigger(:user_updated, user, %w[email])
      DiscourseEvent.trigger(:user_confirmed_email, user, EmailToken.scopes[:email_change])
      DiscourseEvent.trigger(:user_first_logged_in, user)
      expect(Jobs::SyncHubspotUser.jobs.map { |job| job["args"].first["reason"] }).to eq(
        %w[change change change],
      )
    end
  end
end
