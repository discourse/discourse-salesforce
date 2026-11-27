# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Jobs::DiscourseCrm::PullUser do
  include_context "with salesforce spec helper"

  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }

  let!(:configuration) { Fabricate(:salesforce_pull_configuration) }

  before { SiteSetting.enable_guided_sync_configuration = true }

  it "pulls the Salesforce Contact matching the user's email and fills mapped Discourse fields" do
    stub_request(:get, query_path).with(
      query: hash_including("q" => /WHERE Email IN \('ada@example.com'\)\z/),
    ).to_return(
      body: {
        records: [
          {
            "Id" => "003A",
            "Email" => user.email,
            "SystemModstamp" => "2026-11-01T10:00:00.000+0000",
            "Title" => "CTO",
            "Name" => "Ada King",
          },
        ],
      }.to_json,
    )

    described_class.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )

    expect(configuration.record_link_for(user.id).external_id).to eq("003A")
    expect(user.reload.name).to eq("Ada King")
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).pluck(:reason)).to eq(["imported"])
  end

  it "unlinks a user who can no longer be matched without asking Salesforce, then updates segments" do
    SiteSetting.crm_segments_enabled = true
    DiscourseCrm::RecordLink.link_many!(
      [
        {
          provider: "salesforce",
          account: configuration.account,
          object: "Contact",
          direction: "inbound",
          user_id: user.id,
          external_id: "003A",
        },
      ],
    )
    user.update!(suspended_till: 1.year.from_now)

    described_class.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )

    expect(configuration.record_links).to be_empty
    expect(a_request(:get, /#{query_path}/)).not_to have_been_made
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).pluck(:reason)).to eq(
      ["contact_unlinked"],
    )
    expect(
      Jobs::DiscourseCrm::EvaluateSegments.jobs.map { |job| job["args"].first },
    ).to contain_exactly(
      a_hash_including("configuration_id" => configuration.id, "user_ids" => [user.id]),
    )
  end
end
