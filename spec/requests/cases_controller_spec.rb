# frozen_string_literal: true

require "rails_helper"
require_relative "../spec_helper"

RSpec.describe ::Salesforce::CasesController do
  include_context "with salesforce spec helper"

  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic) }
  fab!(:admin)

  describe "#sync" do
    it "creates a new case object in Salesforce" do
      sign_in(admin)
      Salesforce.seed_groups!

      stub_request(:post, "#{api_path}/Contact").with(
        body: topic.user.salesforce_contact_payload.to_json,
      ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

      stub_request(:post, "#{api_path}/Case").with(
        body:
          %({"ContactId":"123456","Subject":"#{topic.title}","Description":"#{first_post.full_url}\\n\\n#{first_post.raw}","Origin":"Web"}),
      ).to_return(status: 200, body: %({"id":"234567"}), headers: {})

      stub_request(:get, "#{api_path}/Case/234567").to_return(
        status: 200,
        body: %({"CaseNumber":"345678","Status":"New"}),
        headers: {
        },
      )

      post "/salesforce/cases/sync.json", params: { topic_id: topic.id }

      expect(response.status).to eq(200)
      salesforce_case = ::Salesforce::Case.last
      expect(salesforce_case.number).to eq("345678")
      expect(salesforce_case.status).to eq("New")
    end

    it "shows a user readable error when credentials are invalid" do
      sign_in(admin)
      Salesforce.seed_groups!

      stub_request(:post, "https://login.salesforce.com/services/oauth2/token").to_return(
        status: 300,
      )

      post "/salesforce/cases/sync.json", params: { topic_id: topic.id }

      expect(response.status).to eq(502)
      expect(JSON.parse(response.body)).to eq(
        { "error" => I18n.t("salesforce.error.invalid_client_credentials") },
      )
    end
  end
end
