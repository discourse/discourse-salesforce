# frozen_string_literal: true

require "rails_helper"
require_relative "../spec_helper"

RSpec.describe ::Salesforce::PersonsController do
  include_context "with salesforce spec helper"

  fab!(:user)
  fab!(:admin)

  describe "#create" do
    before do
      sign_in(admin)
      Salesforce.seed_groups!
    end

    it "creates a new contact object in Salesforce" do
      stub_request(:post, "#{api_path}/Contact").with(
        body: user.salesforce_contact_payload.to_json,
      ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

      post "/salesforce/persons/create.json", params: { type: "contact", user_id: user.id }

      expect(response.status).to eq(200)
      expect(user.salesforce_contact_id).to eq("123456")
    end

    it "creates a new lead object in Salesforce" do
      stub_request(:post, "#{api_path}/Lead").with(
        body: user.salesforce_lead_payload.to_json,
      ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

      post "/salesforce/persons/create.json", params: { type: "lead", user_id: user.id }

      expect(response.status).to eq(200)
      expect(user.salesforce_lead_id).to eq("123456")
    end
  end
end
