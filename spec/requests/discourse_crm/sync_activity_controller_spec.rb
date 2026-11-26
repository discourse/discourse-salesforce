# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::SyncActivityController do
  fab!(:admin)
  fab!(:user)
  fab!(:configuration, :sync_configuration)

  before do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
  end

  def record_attempt(**attributes)
    DiscourseCrm::SyncAttempt
      .record(configuration, user.id)
      .tap { |attempt| attempt.update!(attributes) }
  end

  it "restricts activity history to admins" do
    [nil, user, Fabricate(:moderator)].each do |viewer|
      sign_in(viewer) if viewer
      get "/salesforce/admin/guided-sync/activity.json"
      expect(response).not_to have_http_status(:ok)
    end
  end

  it "lists each configured provider once even when the filtered history is empty" do
    sign_in(admin)
    Fabricate(:sync_configuration)
    Fabricate(:hubspot_sync_configuration)

    get "/salesforce/admin/guided-sync/activity.json", params: { provider: "salesforce" }

    expect(response.parsed_body.fetch("configured_providers")).to contain_exactly(
      "salesforce",
      "hubspot",
    )
  end

  it "returns a readable failure reason without exposing stored diagnostics" do
    sign_in(admin)
    success =
      record_attempt(
        diagnostics: {
          field_values: [{ field: "Member_ID__c", value: "historical-private-value" }],
        },
      )
    failure =
      record_attempt(
        provider: "hubspot",
        outcome: "failed",
        diagnostics: {
          codes: ["INVALID_EMAIL"],
          field_values: [{ field: "Member_ID__c", value: "historical-private-value" }],
        },
      )
    get "/salesforce/admin/guided-sync/activity.json"
    rows = response.parsed_body.fetch("attempts").index_by { |row| row["id"] }
    expect(rows.fetch(success.id)).not_to have_key("diagnostics")
    expect(rows.fetch(success.id)).not_to have_key("failure_reason")
    expect(rows.fetch(failure.id).fetch("failure_reason")).to eq("Invalid email")
    expect(rows.fetch(failure.id)).not_to have_key("diagnostics")
    expect(response.body).not_to include("historical-private-value")
  end

  it "returns a rejected email only while the user owns it, including after a bulk update" do
    sign_in(admin)
    address = Fabricate(:secondary_email, user: user)
    rejected_values = [{ "property" => "email", "value" => address.email.upcase }]
    record_attempt(
      outcome: "failed",
      diagnostics: {
        codes: ["INVALID_EMAIL"],
        rejected_values: [rejected_values.first.merge("message" => "raw provider message")],
      },
    )
    get "/salesforce/admin/guided-sync/activity.json"
    expect(response.parsed_body.fetch("attempts").sole.fetch("rejected_email")).to eq(
      address.email.upcase,
    )
    expect(response.body).not_to include("raw provider message")

    new_email = "new-address@example.org"
    address.update_columns(email: new_email, normalized_email: UserEmail.normalize(new_email))
    Fabricate(:secondary_email, user: admin, email: rejected_values.first.fetch("value").downcase)
    get "/salesforce/admin/guided-sync/activity.json"
    expect(response.parsed_body.fetch("attempts").sole["rejected_email"]).to be_nil
  end

  it "returns converted lead summaries and their counts when filtering by skipped outcome" do
    sign_in(admin)
    started_at = Time.current
    %w[unchanged_summary skipped_converted_summary].each do |reason|
      DiscourseCrm::SyncAttempt.record_check_summary(configuration, started_at, 2, reason: reason)
    end

    get "/salesforce/admin/guided-sync/activity.json", params: { outcome: "skipped" }
    expect(response.parsed_body.fetch("attempts").sole).to include(
      "reason" => "skipped_converted_summary",
      "summary_count" => 2,
    )
  end

  it "matches canonically equivalent Unicode usernames" do
    SiteSetting.unicode_usernames = true
    user.update!(username: "Café")
    attempt = record_attempt
    sign_in(admin)
    get "/salesforce/admin/guided-sync/activity.json",
        params: {
          username: "CAFÉ".unicode_normalize(:nfd),
        }
    expect(response.parsed_body.fetch("attempts").pluck("id")).to eq([attempt.id])
  end

  it "filters between local midnight boundaries, excluding the following midnight" do
    sign_in(admin)
    record_attempt(created_at: "2026-11-22T15:59:59Z")
    first = record_attempt(created_at: "2026-11-22T16:00:00Z")
    last = record_attempt(created_at: "2026-11-23T15:59:59Z")
    record_attempt(created_at: "2026-11-23T16:00:00Z")
    get "/salesforce/admin/guided-sync/activity.json",
        params: {
          from: "2026-11-23T00:00:00+08:00",
          to: "2026-11-24T00:00:00+08:00",
        }
    expect(response.parsed_body.fetch("attempts").pluck("id")).to eq([last.id, first.id])
  end

  it "includes the full local date when daylight saving time starts" do
    sign_in(admin)
    record_attempt(created_at: "2026-03-08T04:59:59Z")
    first = record_attempt(created_at: "2026-03-08T05:00:00Z")
    last = record_attempt(created_at: "2026-03-09T03:59:59Z")
    record_attempt(created_at: "2026-03-09T04:00:00Z")
    get "/salesforce/admin/guided-sync/activity.json",
        params: {
          from: "2026-03-08",
          to: "2026-03-08",
          timezone: "America/New_York",
        }
    expect(response.parsed_body.fetch("attempts").pluck("id")).to eq([last.id, first.id])
  end

  it "lists newest attempts first and combines all filters with inclusive UTC dates" do
    sign_in(admin)
    earlier = record_attempt(created_at: "2026-11-10T12:00:00Z")
    matching = record_attempt(created_at: "2026-11-11T23:59:59Z", outcome: "failed")
    record_attempt(created_at: "2026-11-12T00:00:00Z", outcome: "failed")
    get "/salesforce/admin/guided-sync/activity.json",
        params: {
          outcome: "failed",
          provider: "salesforce",
          username: user.username.upcase,
          from: "2026-11-11",
          to: "2026-11-11",
        }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["attempts"].map { |entry| entry["id"] }).to eq([matching.id])
    get "/salesforce/admin/guided-sync/activity.json"
    expect(response.parsed_body["attempts"].last["id"]).to eq(earlier.id)
    expect(response.parsed_body["attempts"].last["username"]).to eq(user.username)
  end

  it "includes the configuration name and handles deleted configurations" do
    sign_in(admin)
    record_attempt
    get "/salesforce/admin/guided-sync/activity.json"
    expect(response.parsed_body["attempts"].first["configuration"]).to eq(
      "id" => configuration.id,
      "name" => configuration.name,
    )
    configuration.destroy!
    get "/salesforce/admin/guided-sync/activity.json"
    expect(response.parsed_body.fetch("attempts").sole.fetch("configuration")).to be_nil
  end

  it "continues past a deleted cursor row when attempts share a timestamp" do
    sign_in(admin)
    freeze_time
    attempts = Array.new(51) { record_attempt }
    get "/salesforce/admin/guided-sync/activity.json"
    expect(response.parsed_body["attempts"].size).to eq(50)
    attempts.second.destroy!
    get "/salesforce/admin/guided-sync/activity.json",
        params: {
          before: response.parsed_body["next_before"],
        }
    expect(response.parsed_body["attempts"].map { |entry| entry["id"] }).to eq([attempts.first.id])
    expect(response.parsed_body["next_before"]).to be_nil
  end

  it "rejects invalid filters" do
    sign_in(admin)
    [
      { username: ["jane"] },
      { from: "yesterday" },
      { from: "2026-11-11", timezone: "unknown" },
      { from: "2026-11-11T00:00:00+25:00" },
      { to: "2026-11-11T00:00:00+08:60" },
      { to: "2026-02-30" },
      { outcome: "unknown" },
      { before: "-1" },
      { from: "2026-11-12", to: "2026-11-11" },
    ].each do |params|
      get "/salesforce/admin/guided-sync/activity.json", params: params
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "redirects an activity bookmark to Settings when both providers are disabled" do
    sign_in(admin)
    SiteSetting.salesforce_enabled = false
    SiteSetting.hubspot_enabled = false

    get "/admin/plugins/discourse-salesforce/activity", headers: { "ACCEPT" => "text/html" }
    expect(response).to redirect_to("/admin/plugins/discourse-salesforce/settings")

    get "/salesforce/admin/guided-sync/activity.json"
    expect(response).to have_http_status(:not_found)
  end

  it "hides the page and activity history when guided sync is disabled" do
    sign_in(admin)
    SiteSetting.enable_guided_sync_configuration = false
    %w[
      /admin/plugins/discourse-salesforce/activity
      /salesforce/admin/guided-sync/activity.json
    ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
  end
end
