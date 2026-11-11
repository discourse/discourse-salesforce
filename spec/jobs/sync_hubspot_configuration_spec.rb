# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::SyncHubspotConfiguration do
  include_context "with hubspot spec helper"

  let!(:configuration) { Fabricate(:hubspot_sync_configuration) }

  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }

  def enqueued_args
    Jobs::SyncHubspotConfiguration.jobs.map { |job| job["args"].first.except("current_site_id") }
  end

  before { Jobs::SyncHubspotConfiguration.clear }

  it "lists every contact on backfill, follows the cursor and records the run start as the sync time" do
    freeze_time Time.utc(2026, 11, 2, 12)
    started_at = Time.zone.now
    stub_hubspot_contact_list([hubspot_contact(501, "ada@example.com")], after: "100")

    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    expect(
      a_request(:get, hubspot_url("objects/contacts")).with(
        query: {
          limit: 100,
          properties: "email,lastmodifieddate,lifecyclestage,jobtitle",
        },
      ),
    ).to have_been_made.once
    expect(Salesforce::RecordLink.where(user_id: user.id).pluck(:external_id)).to eq(["501"])
    expect(configuration.reload.last_synced_at).to be_nil
    expect(enqueued_args).to eq(
      [
        {
          "configuration_id" => configuration.id,
          "reason" => "backfill",
          "started_at" => started_at.iso8601,
          "after" => "100",
        },
      ],
    )

    stub_hubspot_contact_list([], query: { after: "100" })
    freeze_time 10.minutes.from_now
    described_class.new.execute(enqueued_args.first.symbolize_keys)

    expect(configuration.reload.last_synced_at).to eq_time(started_at)
  end

  it "searches contacts modified since the previous run with an overlap and never moves the sync time backwards" do
    configuration.update!(last_synced_at: Time.utc(2026, 11, 1, 12), last_error: "Boom")
    freeze_time Time.utc(2026, 11, 2, 12)
    stub_hubspot_contact_search([hubspot_contact(501, "ada@example.com")])

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(
      a_request(:post, hubspot_url("objects/contacts/search")).with(
        body:
          hash_including(
            "filterGroups" => [
              {
                "filters" => [
                  {
                    "propertyName" => "lastmodifieddate",
                    "operator" => "GTE",
                    "value" => Time.utc(2026, 11, 1, 11, 55).to_i.*(1000).to_s,
                  },
                ],
              },
            ],
            "sorts" => [{ "propertyName" => "lastmodifieddate", "direction" => "ASCENDING" }],
          ),
      ),
    ).to have_been_made.once
    expect(configuration.reload.slice(:last_synced_at, :last_error, :last_error_at)).to eq(
      "last_synced_at" => Time.utc(2026, 11, 2, 12),
      "last_error" => nil,
      "last_error_at" => nil,
    )

    described_class.new.execute(
      configuration_id: configuration.id,
      reason: "scheduled",
      started_at: Time.utc(2026, 11, 2, 11).iso8601,
    )

    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
  end

  it "lists every contact on a scheduled run that has never synced" do
    stub_hubspot_contact_list([])

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(
      a_request(:get, hubspot_url("objects/contacts")).with(query: hash_including({})),
    ).to have_been_made.once
    expect(a_request(:post, hubspot_url("objects/contacts/search"))).not_to have_been_made
  end

  it "restarts the search from the last modified date when the cursor reaches HubSpot's limit" do
    freeze_time Time.utc(2026, 11, 2, 12)
    configuration.update!(last_synced_at: 1.day.ago)
    stub_hubspot_contact_search(
      [hubspot_contact(501, "ada@example.com", lastmodifieddate: "2026-11-02T09:30:00.000Z")],
      after: "10000",
    )

    described_class.new.execute(
      configuration_id: configuration.id,
      reason: "scheduled",
      after: "9900",
      since: 1.day.ago.iso8601,
      started_at: Time.zone.now.iso8601,
    )

    expect(enqueued_args).to contain_exactly(
      {
        "configuration_id" => configuration.id,
        "reason" => "scheduled",
        "started_at" => Time.zone.now.iso8601,
        "since" => Time.utc(2026, 11, 2, 9, 30).iso8601,
      },
    )
  end

  it "stops with an error when the search limit is reached without a later modified date" do
    freeze_time Time.utc(2026, 11, 2, 12)
    since = Time.utc(2026, 11, 2, 9, 30)
    stub_hubspot_contact_search(
      [hubspot_contact(501, "ada@example.com", lastmodifieddate: since.iso8601(3))],
      after: "10000",
    )

    expect {
      described_class.new.execute(
        configuration_id: configuration.id,
        reason: "scheduled",
        after: "9900",
        since: since.iso8601,
        started_at: Time.zone.now.iso8601,
      )
    }.to raise_error(Hubspot::InvalidApiResponse, /without a later modified date/)

    expect(enqueued_args).to be_empty
    expect(configuration.reload.last_error).to eq("Hubspot::InvalidApiResponse")
  end

  it "keeps searching with the same window across pages of a scheduled run" do
    configuration.update!(last_synced_at: Time.utc(2026, 11, 1, 12))
    freeze_time Time.utc(2026, 11, 2, 12)
    stub_hubspot_contact_search([hubspot_contact(501, "ada@example.com")], after: "100")

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    described_class.new.execute(enqueued_args.first.symbolize_keys)

    expect(enqueued_args.first).to include(
      "after" => "100",
      "since" => Time.utc(2026, 11, 1, 11, 55).iso8601,
    )
    expect(
      a_request(:post, hubspot_url("objects/contacts/search")).with(
        body:
          hash_including(
            "after" => "100",
            "filterGroups" => [
              {
                "filters" => [
                  {
                    "propertyName" => "lastmodifieddate",
                    "operator" => "GTE",
                    "value" => Time.utc(2026, 11, 1, 11, 55).to_i.*(1000).to_s,
                  },
                ],
              },
            ],
          ),
      ),
    ).to have_been_made.once
    expect(
      a_request(:get, hubspot_url("objects/contacts")).with(query: hash_including({})),
    ).not_to have_been_made
  end

  it "waits for the rate limit window before retrying the same page" do
    configuration.update!(last_synced_at: 1.day.ago)
    stub_hubspot_contact_search([], status: 429, headers: { "Retry-After" => "17" })
    freeze_time

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(Jobs::SyncHubspotConfiguration.jobs.map { |job| job["at"] - Time.now.to_f }).to all(
      be_within(1).of(17),
    )
    expect(configuration.reload.last_error).to be_nil
  end

  it "records failures on the configuration and raises so the job retries" do
    stub_request(:get, hubspot_url("objects/contacts")).with(query: hash_including({})).to_return(
      status: 500,
      body: "boom",
    )

    expect {
      described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    }.to raise_error(Hubspot::InvalidApiResponse)

    expect(configuration.reload.last_error).to eq("Hubspot::InvalidApiResponse")
  end

  it "does nothing for inactive configurations, disabled reasons or a disabled provider" do
    SiteSetting.hubspot_portal_id = "99999"
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    SiteSetting.hubspot_portal_id = "12345"
    configuration.update!(schedule: "manual", backfill: false)
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    configuration.update!(schedule: "daily", backfill: true)
    SiteSetting.hubspot_enabled = false
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    expect(a_request(:any, /api.hubapi.com/)).not_to have_been_made
  end
end
