# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Jobs::Hubspot::SyncConfiguration do
  include_context "with hubspot spec helper"

  let!(:configuration) { Fabricate(:hubspot_sync_configuration) }

  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }

  def enqueued_args
    Jobs::Hubspot::SyncConfiguration.jobs.map { |job| job["args"].first.except("current_site_id") }
  end

  before do
    Jobs::Hubspot::SyncConfiguration.clear
    Jobs::DiscourseCrm::EvaluateSegments.clear
    SiteSetting.crm_segments_enabled = true
  end

  it "keeps a paged contact unlink and its history atomic across retries" do
    args = { configuration_id: configuration.id, reason: "backfill" }
    stub_hubspot_contact_list([hubspot_contact(501, user.email)])
    described_class.new.execute(args)
    stub_hubspot_contact_list([hubspot_contact(501, "other@example.org")])
    DiscourseCrm::SyncConfiguration
      .any_instance
      .stubs(:record_import_results)
      .raises(ActiveRecord::Deadlocked)
    expect { described_class.new.execute(args) }.to raise_error(ActiveRecord::Deadlocked)
    expect(configuration.record_links.pluck(:external_id)).to eq(["501"])
    DiscourseCrm::SyncConfiguration.any_instance.unstub(:record_import_results)
    described_class.new.execute(args)
    expect(configuration.record_links).to be_empty
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported contact_unlinked],
    )
  end

  it "clears recovered users' quota errors without clearing failures outside the imported page" do
    other_user = Fabricate(:verified_user)
    outbound =
      Fabricate(:sync_configuration, provider: "hubspot", account: "12345", object: "contact")
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      status: 429,
      body: { policyName: "DAILY" }.to_json,
    )
    Jobs::DiscourseCrm::PullUser.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::DailyQuotaExceeded")
    [[configuration, other_user], [outbound, user]].each do |record, member|
      DiscourseCrm::SyncConfiguration.record_result(
        record.id,
        member.id,
        error: Hubspot::DailyQuotaExceeded.new,
      )
    end
    stub_hubspot_contact_list([hubspot_contact(501, user.email, jobtitle: "Engineer")])

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(configuration.record_link_for(user.id).external_id).to eq("501")
    expect(configuration.reload.last_synced_at).to be_present
    expect(configuration.sync_states.find_by(user_id: user.id).slice(:error, :error_at)).to eq(
      "error" => nil,
      "error_at" => nil,
    )
    expect(configuration.sync_states.find_by(user_id: other_user.id).error).to eq(
      "Hubspot::DailyQuotaExceeded",
    )
    expect(outbound.sync_states.find_by(user_id: user.id).error).to eq(
      "Hubspot::DailyQuotaExceeded",
    )
    expect(configuration.sync_status["error"]).to eq("Hubspot::DailyQuotaExceeded")
    stub_hubspot_contact_search([hubspot_contact(502, other_user.email)])
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    expect(configuration.reload.sync_status).not_to have_key("error")
  end

  it "fills mapped Discourse fields and records rejected values once per scheduled pull" do
    title = Fabricate(:user_field, name: "Job title", field_type: "text")
    renewal = Fabricate(:user_field, name: "Renewal", field_type: "date")
    configuration.update!(
      mappings: [
        {
          "object" => "contact",
          "source" => "jobtitle",
          "destination" => "user_field_#{title.id}",
          "policy" => "overwrite",
        },
        {
          "object" => "contact",
          "source" => "renewal",
          "destination" => "user_field_#{renewal.id}",
          "policy" => "overwrite",
        },
      ],
    )
    stub_hubspot_contact_list(
      [hubspot_contact(501, user.email, jobtitle: "CTO", renewal: "next spring")],
    )

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(user.reload.user_fields[title.id.to_s]).to eq("CTO")
    expect(user.user_fields[renewal.id.to_s]).to be_nil
    failure = DiscourseCrm::SyncAttempt.find_by(user_id: user.id, outcome: "failed")
    expect(failure.error_class).to eq("DiscourseCrm::InvalidDestinationValue")
    expect(failure.diagnostics).to eq("destinations" => ["user_field_#{renewal.id}"])
    expect(configuration.reload.last_synced_at).to be_present

    stub_hubspot_contact_search(
      [hubspot_contact(501, user.email, jobtitle: "CTO", renewal: "next spring")],
    )
    expect {
      described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    }.to change { DiscourseCrm::SyncAttempt.where(configuration_id: configuration.id).count }.by(1)
    expect(DiscourseCrm::SyncAttempt.last).to have_attributes(user_id: user.id, outcome: "failed")
  end

  it "records an unlink for the previous owner when a contact changes email" do
    other_user = Fabricate(:verified_user)
    args = { configuration_id: configuration.id, reason: "backfill" }
    stub_hubspot_contact_list([hubspot_contact(501, user.email)])
    described_class.new.execute(args)
    stub_hubspot_contact_list([hubspot_contact(501, other_user.email)])
    described_class.new.execute(args)
    expect(configuration.record_links.pluck(:user_id)).to eq([other_user.id])
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported contact_unlinked],
    )
    expect(DiscourseCrm::SyncAttempt.where(user_id: other_user.id).sole.reason).to eq("imported")
  end

  it "records only an unlink for a user whose other contact is unchanged on the scheduled page" do
    next_owner = Fabricate(:verified_user)
    retained = hubspot_contact(501, user.email)
    stub_hubspot_contact_list([retained, hubspot_contact(502, user.email)])
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    stub_hubspot_contact_search([retained, hubspot_contact(502, next_owner.email)])
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported contact_unlinked],
    )
    expect(DiscourseCrm::SyncAttempt.where(user_id: next_owner.id).sole.reason).to eq("imported")
  end

  it "records the first unchanged scheduled pull after a user's rate limit in their history" do
    contact = hubspot_contact(501, user.email)
    stub_hubspot_contact_list([contact])
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      status: 429,
      headers: {
        "Retry-After" => "17",
      },
    )
    Jobs::DiscourseCrm::PullUser.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )

    Discourse.redis.without_namespace.expire("hubspot_api:12345:6789:cooldown", 0)
    stub_hubspot_contact_search([contact])
    2.times { described_class.new.execute(configuration_id: configuration.id, reason: "scheduled") }
    expect(
      DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:outcome, :reason),
    ).to eq([%w[success imported], %w[failed failed], %w[success unchanged]])
    expect(DiscourseCrm::SyncAttempt.where(reason: "unchanged_summary").sole.diagnostics).to eq(
      "count" => 1,
    )
  end

  it "records daily quota exhaustion without scheduling another import" do
    stub_request(:get, %r{api.hubapi.com/crm/v3/objects/contacts}).to_return(
      status: 429,
      body: { policyName: "DAILY" }.to_json,
    )
    described_class.clear
    expect {
      described_class.new.execute(
        configuration_id: configuration.id,
        user_id: user.id,
        reason: "backfill",
      )
    }.not_to raise_error
    expect(described_class.jobs).to be_empty
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::DailyQuotaExceeded")
  end

  it "summarizes an unchanged contact from an overlapping search and reports later mapped changes" do
    configuration.update!(last_synced_at: 1.hour.ago)
    args = { configuration_id: configuration.id, reason: "scheduled" }
    stub_hubspot_contact_search([hubspot_contact(501, user.email, jobtitle: "Engineer")])
    2.times { described_class.new.execute(args) }
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).pluck(:reason)).to eq(["imported"])
    expect(DiscourseCrm::SyncAttempt.where(user_id: nil).sole).to have_attributes(
      reason: "unchanged_summary",
      diagnostics: {
        "count" => 1,
      },
    )

    stub_hubspot_contact_search([hubspot_contact(501, user.email, jobtitle: "Designer")])
    described_class.new.execute(args)
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported imported],
    )
  end

  it "lists every contact on backfill, follows the cursor and records the run start as the sync time" do
    freeze_time Time.utc(2026, 11, 2, 12)
    started_at = Time.zone.now
    stub_hubspot_contact_list([hubspot_contact(501, "ada@example.com")], after: "100")

    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    expect(
      a_request(:get, hubspot_url("objects/contacts")).with(
        query: {
          limit: 100,
          properties: "email,lastmodifieddate,associatedcompanyid,lifecyclestage,jobtitle",
        },
      ),
    ).to have_been_made.once
    expect(DiscourseCrm::RecordLink.where(user_id: user.id).pluck(:external_id)).to eq(["501"])
    expect(configuration.reload.last_synced_at).to be_nil
    expect(Jobs::DiscourseCrm::EvaluateSegments.jobs).to be_empty
    expect(enqueued_args).to eq(
      [
        {
          "configuration_id" => configuration.id,
          "account" => configuration.account,
          "reason" => "backfill",
          "started_at" => started_at.iso8601,
          "history_result" => "recorded",
          "after" => "100",
        },
      ],
    )

    stub_hubspot_contact_list([], query: { after: "100" })
    freeze_time 10.minutes.from_now
    described_class.new.execute(enqueued_args.first.symbolize_keys)

    expect(DiscourseCrm::SyncAttempt.where(user_id: nil)).to be_empty
    expect(configuration.reload.last_synced_at).to eq_time(started_at)
    expect(
      Jobs::DiscourseCrm::EvaluateSegments.jobs.map { |job| job["args"].first },
    ).to contain_exactly(hash_including("configuration_id" => configuration.id))
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
        "account" => configuration.account,
        "reason" => "scheduled",
        "started_at" => Time.zone.now.iso8601,
        "since" => Time.utc(2026, 11, 2, 9, 30).iso8601,
        "history_result" => "recorded",
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
    expect(
      DiscourseCrm::SyncAttempt.where(outcome: "failed").sole.diagnostics.fetch("codes"),
    ).to eq(["CONTACT_SEARCH_LIMIT"])

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

    expect(Jobs::Hubspot::SyncConfiguration.jobs.map { |job| job["at"] - Time.now.to_f }).to all(
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

  it "records an unmatched pull once, even when its last page is empty" do
    stub_hubspot_contact_list([hubspot_contact(123, "unmatched@example.com")], after: "100")
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    stub_hubspot_contact_list([], query: { after: "100" })
    described_class.new.execute(enqueued_args.last.symbolize_keys)
    expect(DiscourseCrm::SyncAttempt.sole).to have_attributes(
      user_id: nil,
      reason: "no_matching_users",
    )
  end

  it "finishes a scheduled run when no contact changed" do
    freeze_time Time.utc(2026, 11, 2, 12)
    configuration.update!(last_synced_at: Time.utc(2026, 11, 1, 12))
    stub_hubspot_contact_search([])

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
    expect(DiscourseCrm::SyncAttempt.sole).to have_attributes(
      user_id: nil,
      reason: "no_contacts",
      outcome: "success",
    )
    expect(enqueued_args).to be_empty
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
