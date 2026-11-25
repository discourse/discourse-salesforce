# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Jobs::Hubspot::SyncUser do
  include_context "with hubspot spec helper"

  let!(:configuration) do
    Fabricate(:hubspot_sync_configuration, last_synced_at: Time.utc(2026, 11, 1, 12))
  end

  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }

  before do
    freeze_time Time.utc(2026, 11, 2, 12)
    Jobs::DiscourseCrm::EvaluateSegments.clear
    SiteSetting.crm_segments_enabled = true
  end

  it "records daily quota exhaustion without scheduling another import" do
    stub_request(:post, %r{api.hubapi.com/crm/v3/objects/contacts/batch/read}).to_return(
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

  it "links the user's contacts and clears a previous error without touching the sync time" do
    DiscourseCrm::SyncState.store(configuration.id, user.id, error: "Boom", error_at: Time.zone.now)
    stub_hubspot_batch_read([hubspot_contact(501, "ada@example.com")])

    described_class.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )

    expect(DiscourseCrm::RecordLink.where(user_id: user.id).pluck(:external_id)).to eq(["501"])
    expect(configuration.sync_states.find_by(user_id: user.id).error).to be_nil
    expect(DiscourseCrm::SyncAttempt.last).to have_attributes(
      reason: "imported",
      direction: "inbound",
    )
    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 1, 12))
    expect(
      Jobs::DiscourseCrm::EvaluateSegments.jobs.map { |job| job["args"].first },
    ).to contain_exactly(
      hash_including("provider" => "hubspot", "account" => "12345", "user_ids" => [user.id]),
    )
  end

  it "rolls back a contact unlink when its history write fails and records it on retry" do
    args = { configuration_id: configuration.id, user_id: user.id, reason: "change" }
    stub_hubspot_batch_read([hubspot_contact(501, user.email)])
    described_class.new.execute(args)
    stub_hubspot_batch_read([])
    DiscourseCrm::SyncConfiguration
      .any_instance
      .stubs(:record_import_results)
      .raises(ActiveRecord::Deadlocked)
    expect { described_class.new.execute(args) }.to raise_error(ActiveRecord::Deadlocked)
    expect(configuration.record_links.pluck(:external_id)).to eq(["501"])
    DiscourseCrm::SyncConfiguration.any_instance.unstub(:record_import_results)
    described_class.new.execute(args)
    expect(configuration.record_links).to be_empty
    expect(DiscourseCrm::SyncAttempt.order(:id).pluck(:reason)).to eq(
      %w[imported failed contact_unlinked],
    )
  end

  it "records one import for a user with multiple matching email addresses" do
    UserEmail.create!(user: user, email: "ada.work@example.com")
    stub_hubspot_batch_read(
      [
        hubspot_contact(501, "ada@example.com", lifecyclestage: "customer"),
        hubspot_contact(502, "ada.work@example.com", lifecyclestage: "lead"),
      ],
    )
    described_class.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )
    expect(DiscourseCrm::SyncAttempt.sole).to have_attributes(
      user_id: user.id,
      reason: "imported",
      diagnostics: {
      },
    )
  end

  it "distinguishes removing a stale contact link from a subsequent empty lookup" do
    args = { configuration_id: configuration.id, user_id: user.id, reason: "change" }
    stub_hubspot_batch_read([hubspot_contact(501, user.email)])
    described_class.new.execute(args)
    stub_hubspot_batch_read([])
    2.times { described_class.new.execute(args) }

    expect(configuration.record_links).to be_empty
    expect(DiscourseCrm::SyncAttempt.order(:id).pluck(:outcome, :reason)).to eq(
      [%w[success imported], %w[success contact_unlinked], %w[skipped skipped_no_match]],
    )
  end

  it "reports both a missing company and a stale contact removed during the same pull" do
    configuration.update!(mappings: [{ "id" => 1, "object" => "company", "source" => "name" }])
    args = { configuration_id: configuration.id, user_id: user.id, reason: "change" }
    stub_hubspot_batch_read([hubspot_contact(501, user.email)])
    described_class.new.execute(args)

    stub_hubspot_batch_read([hubspot_contact(502, user.email, associatedcompanyid: "c001")])
    stub_hubspot_company_batch_read(
      [],
      errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: ["c001"] } }],
    )
    described_class.new.execute(args)

    expect(configuration.record_links.pluck(:external_id)).to eq(["502"])
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported imported_and_unlinked_missing_company],
    )
  end

  it "keeps existing links when a partial read cannot confirm the user's full contact set" do
    args = { configuration_id: configuration.id, user_id: user.id, reason: "change" }
    UserEmail.create!(user: user, email: "ada.work@example.com")
    contacts = [hubspot_contact(501, user.email), hubspot_contact(502, "ada.work@example.com")]
    stub_hubspot_batch_read(contacts)
    described_class.new.execute(args)
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      status: 207,
      body: {
        results: [contacts.first],
        errors: [
          {
            category: "VALIDATION_ERROR",
            code: "INVALID_EMAIL",
            name: "email",
            value: "ada.work@example.com",
          },
        ],
      }.to_json,
    )
    described_class.new.execute(args)
    expect(configuration.record_links.pluck(:external_id)).to contain_exactly("501", "502")
    expect(DiscourseCrm::SyncAttempt.last.diagnostics).to include("codes" => ["INVALID_EMAIL"])
    stub_hubspot_batch_read([contacts.first])
    described_class.new.execute(args)
    expect(configuration.record_links.pluck(:external_id)).to eq(["501"])
    expect(DiscourseCrm::SyncAttempt.last.reason).to eq("imported_and_unlinked")
  end

  it "preserves contact links when HubSpot reports errors without identifying them" do
    args = { configuration_id: configuration.id, user_id: user.id, reason: "change" }
    stub_hubspot_batch_read([hubspot_contact(501, user.email)])
    described_class.new.execute(args)
    [[], [{ category: "OBJECT_NOT_FOUND" }]].each do |errors|
      stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
        status: 207,
        body: {
          status: "COMPLETE",
          results: [],
          numErrors: errors.size + 1,
          errors: errors,
        }.to_json,
      )
      expect { described_class.new.execute(args) }.to raise_error(Hubspot::InvalidApiResponse)
      expect(configuration.record_links.pluck(:external_id)).to eq(["501"])
      expect(DiscourseCrm::SyncAttempt.last.outcome).to eq("failed")
    end
  end

  it "records the former and current owners when an individual pull moves a contact" do
    next_owner = Fabricate(:verified_user)
    args = { configuration_id: configuration.id, reason: "change" }
    stub_hubspot_batch_read([hubspot_contact(501, user.email)])
    described_class.new.execute(args.merge(user_id: user.id))
    stub_hubspot_batch_read([hubspot_contact(501, next_owner.email)])
    described_class.new.execute(args.merge(user_id: next_owner.id))

    expect(configuration.record_links.pluck(:user_id, :external_id)).to eq([[next_owner.id, "501"]])
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported contact_unlinked],
    )
    expect(DiscourseCrm::SyncAttempt.where(user_id: next_owner.id).sole.reason).to eq("imported")
  end

  it "retries a partial response containing a server error regardless of error order" do
    args = { configuration_id: configuration.id, user_id: user.id, reason: "change" }
    stub_hubspot_batch_read([hubspot_contact(501, user.email)])
    described_class.new.execute(args)
    errors = [
      { category: "VALIDATION_ERROR", code: "INVALID_EMAIL" },
      { category: "INTERNAL_ERROR" },
    ]
    [errors, errors.reverse].each do |items|
      stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
        status: 207,
        body: { results: [], errors: items }.to_json,
      )
      expect { described_class.new.execute(args) }.to raise_error(
        Hubspot::InvalidApiResponse,
      ) { |error| expect(error).to be_retryable }
    end
    expect(configuration.record_links.pluck(:external_id)).to eq(["501"])
    expect(DiscourseCrm::SyncAttempt.order(:id).pluck(:outcome)).to eq(%w[success failed failed])
  end

  it "records a per-user error and raises for retries" do
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(status: 503)

    expect {
      described_class.new.execute(
        configuration_id: configuration.id,
        user_id: user.id,
        reason: "change",
      )
    }.to raise_error(Hubspot::InvalidApiResponse)

    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::InvalidApiResponse")
  end

  it "skips ineligible users" do
    user.update!(suspended_till: 1.day.from_now)

    described_class.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )

    expect(a_request(:any, /api.hubapi.com/)).not_to have_been_made
  end
end
