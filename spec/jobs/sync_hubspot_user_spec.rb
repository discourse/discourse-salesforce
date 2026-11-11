# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::SyncHubspotUser do
  include_context "with hubspot spec helper"

  let!(:configuration) do
    Fabricate(:hubspot_sync_configuration, last_synced_at: Time.utc(2026, 11, 1, 12))
  end

  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }

  before { freeze_time Time.utc(2026, 11, 2, 12) }

  it "links the user's contacts and clears a previous error without touching the sync time" do
    Salesforce::SyncState.store(configuration.id, user.id, error: "Boom", error_at: Time.zone.now)
    stub_hubspot_batch_read([hubspot_contact(501, "ada@example.com")])

    described_class.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )

    expect(Salesforce::RecordLink.where(user_id: user.id).pluck(:external_id)).to eq(["501"])
    expect(configuration.sync_states.find_by(user_id: user.id).error).to be_nil
    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 1, 12))
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
