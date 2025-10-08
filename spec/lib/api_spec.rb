# frozen_string_literal: true

require "rails_helper"
require_relative "../spec_helper"

RSpec.describe ::Salesforce::Api do
  include_context "with salesforce spec helper"

  it "sets Salesforce access token and instance URL" do
    api = described_class.new
    expect(SiteSetting.salesforce_instance_url).to eq(instance_url)
    expect(api.access_token).to eq(access_token)
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
      expect(problem.message).to eq(
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
