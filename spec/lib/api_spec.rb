# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::Api do
  include_context "with salesforce spec helper"

  it "sets Salesforce access token and instance URL" do
    api = described_class.new
    expect(SiteSetting.salesforce_instance_url).to eq(instance_url)
    expect(api.access_token).to eq(access_token)
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

  describe "#get" do
    let(:record_path) { "sobjects/Case/Discourse_Topic_Key__c/missing" }
    let(:record_url) { "#{api_path}/Case/Discourse_Topic_Key__c/missing" }

    it "returns nil for an allowed Salesforce NOT_FOUND response" do
      stub_request(:get, record_url).to_return(
        status: 404,
        body: [
          { errorCode: "NOT_FOUND", message: "The requested resource does not exist" },
        ].to_json,
      )

      expect(described_class.new.get(record_path, allow_not_found: true)).to be_nil
    end

    it "raises for an empty 404 response" do
      stub_request(:get, record_url).to_return(status: 404, body: "")

      expect { described_class.new.get(record_path, allow_not_found: true) }.to raise_error(
        Salesforce::InvalidApiResponse,
      )
    end

    it "raises for a different Salesforce 404 error" do
      stub_request(:get, record_url).to_return(
        status: 404,
        body: [{ errorCode: "INVALID_FIELD", message: "No such field" }].to_json,
      )

      expect { described_class.new.get(record_path, allow_not_found: true) }.to raise_error(
        Salesforce::InvalidApiResponse,
      )
    end

    it "raises when NOT_FOUND has a different HTTP status" do
      stub_request(:get, record_url).to_return(
        status: 400,
        body: [
          { errorCode: "NOT_FOUND", message: "The requested resource does not exist" },
        ].to_json,
      )

      expect { described_class.new.get(record_path, allow_not_found: true) }.to raise_error(
        Salesforce::InvalidApiResponse,
      )
    end
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
