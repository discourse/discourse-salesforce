# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::Lead do
  include_context "with salesforce spec helper"

  describe ".create!" do
    fab!(:user)

    before do
      Salesforce.seed_groups!
      stub_salesforce_person_lookup("Lead", user.email)
    end

    it "sends the configured lead source" do
      SiteSetting.salesforce_lead_source = "Community"

      create_lead =
        stub_request(:post, "#{api_path}/Lead").with(
          body: hash_including(LeadSource: "Community"),
        ).to_return(status: 200, body: %({"id":"123456"}))

      described_class.create!(user)

      expect(create_lead).to have_been_requested
    end

    it "omits the lead source when it is blank" do
      SiteSetting.salesforce_lead_source = ""

      create_lead =
        stub_request(:post, "#{api_path}/Lead")
          .with { |request| JSON.parse(request.body).exclude?("LeadSource") }
          .to_return(status: 200, body: %({"id":"123456"}))

      described_class.create!(user)

      expect(create_lead).to have_been_requested
    end
  end
end
