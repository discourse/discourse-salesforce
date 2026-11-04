# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::Api do
  include_context "with salesforce spec helper"

  it "sets Salesforce access token and instance URL" do
    api = described_class.new
    expect(SiteSetting.salesforce_instance_url).to eq(instance_url)
    expect(api.access_token).to eq(access_token)
  end

  it "preserves temporary authentication server errors for connection diagnostics" do
    stub_request(:post, "https://login.salesforce.com/services/oauth2/token").to_return(
      status: 503,
      body: "private upstream response",
    )
    expect { described_class.new }.to raise_error(Salesforce::InvalidApiResponse) { |error|
      expect(error.status).to eq(503)
    }
  end

  it "shares metadata across clients, expires it, and honors explicit refreshes" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    field = { name: "Email", type: "email", createable: true, updateable: true }
    lookup =
      stub_request(:get, "#{api_path}/Contact/describe").to_return(
        body: { fields: [field] }.to_json,
      )
    freeze_time
    api = described_class.new

    expect(api.cached_writable_fields("Contact")).to eq([field.stringify_keys])
    expect(described_class.cached_writable_fields("Contact")).to eq([field.stringify_keys])
    expect(lookup).to have_been_requested.once

    freeze_time 2.hours.from_now + 1.second
    api.cached_writable_fields("Contact")
    expect(lookup).to have_been_requested.twice
    api.cached_writable_fields("Contact", refresh: true)
    expect(lookup).to have_been_requested.times(3)

    SiteSetting.salesforce_username = "different-integration-user"
    described_class.cached_writable_fields("Contact")
    expect(lookup).to have_been_requested.times(4)
  end

  it "escapes plus signs in SOQL query parameters" do
    soql = "SELECT Id FROM Contact WHERE Email = 'team+salesforce-discourse-dev-ed@example.com'"

    stub_request(:get, query_path).with(query: { q: soql }).to_return(
      status: 200,
      body: { totalSize: 0, records: [] }.to_json,
      headers: {
      },
    )

    described_class.new.query(soql)

    expect(a_request(:get, query_path).with(query: { q: soql })).to have_been_made
  end

  it "returns invalid credentials error when Salesforce client ID is blank" do
    SiteSetting.salesforce_client_id = ""

    expect { described_class.new }.to raise_error(::Salesforce::InvalidCredentials)

    problem = AdminNotice.find_by(identifier: "salesforce_invalid_credentials")
    expect(problem.message).to eq(I18n.t("dashboard.problem.salesforce_invalid_credentials"))
    expect(ProblemCheckTracker["salesforce_invalid_credentials"].failing?).to eq(true)
  end

  context "when app is not approved" do
    let(:api_response_status) { 400 }
    let(:api_response_body) { "user hasn't approved this consumer" }

    it "creates an admin notice if the app is not approved" do
      SiteSetting.salesforce_client_id = "client_id"

      expect { described_class.new }.to raise_error(::Salesforce::InvalidCredentials)

      problem = AdminNotice.find_by(identifier: "salesforce_app_not_approved")
      expect(problem.message).to match_html(
        I18n.t("dashboard.problem.salesforce_app_not_approved", base_path: Discourse.base_path),
      )
      expect(ProblemCheckTracker["salesforce_app_not_approved"].failing?).to eq(true)
    end
  end

  it "resets invalid credentials error when Salesforce client ID is present" do
    SiteSetting.salesforce_client_id = "client_id"
    ProblemCheckTracker["salesforce_invalid_credentials"].problem!
    ProblemCheckTracker["salesforce_app_not_approved"].problem!

    described_class.new

    expect(ProblemCheckTracker["salesforce_invalid_credentials"].failing?).to eq(false)
    expect(ProblemCheckTracker["salesforce_app_not_approved"].failing?).to eq(false)
  end
end
