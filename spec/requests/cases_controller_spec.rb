# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::CasesController do
  include_context "with salesforce spec helper"

  fab!(:topic)
  fab!(:first_post) { Fabricate(:post, topic: topic) }
  fab!(:admin)
  fab!(:moderator)

  describe "#sync" do
    %i[admin moderator].each do |role|
      it "creates a new case object in Salesforce as #{role}" do
        SiteSetting.salesforce_allow_moderators_to_create_cases = true if role == :moderator
        sign_in(public_send(role))
        Salesforce.seed_groups!

        stub_salesforce_person_lookup("Contact", topic.user.email)

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
    end

    it "denies moderators by default" do
      sign_in(moderator)

      post "/salesforce/cases/sync.json", params: { topic_id: topic.id }

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(topic_id: topic.id)).to eq(false)
    end

    it "denies regular users even when moderator access is enabled" do
      SiteSetting.salesforce_allow_moderators_to_create_cases = true
      sign_in(topic.user)

      post "/salesforce/cases/sync.json", params: { topic_id: topic.id }

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(topic_id: topic.id)).to eq(false)
    end

    it "requires login even when moderator access is enabled" do
      SiteSetting.salesforce_allow_moderators_to_create_cases = true

      post "/salesforce/cases/sync.json", params: { topic_id: topic.id }

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(topic_id: topic.id)).to eq(false)
    end

    it "denies moderators access to private messages they cannot see" do
      SiteSetting.salesforce_allow_moderators_to_create_cases = true
      private_topic = Fabricate(:private_message_topic)
      sign_in(moderator)

      post "/salesforce/cases/sync.json", params: { topic_id: private_topic.id }

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(topic_id: private_topic.id)).to eq(false)
    end

    it "allows moderators to sync existing cases when enabled" do
      SiteSetting.salesforce_allow_moderators_to_create_cases = true
      salesforce_case = Fabricate(:salesforce_case, topic: topic)
      sign_in(moderator)
      stub_request(:get, "#{api_path}/Case/#{salesforce_case.uid}").to_return(
        status: 200,
        body: { CaseNumber: salesforce_case.number, Status: "Closed" }.to_json,
      )

      post "/salesforce/cases/sync.json", params: { topic_id: topic.id }

      expect(response.status).to eq(200)
      expect(salesforce_case.reload.status).to eq("Closed")
      expect(response.parsed_body.dig("case", "status")).to eq("Closed")
    end

    it "returns the Salesforce error when case creation is rejected" do
      sign_in(admin)
      Salesforce.seed_groups!

      stub_salesforce_person_lookup("Contact", topic.user.email)

      stub_request(:post, "#{api_path}/Contact").with(
        body: topic.user.salesforce_contact_payload.to_json,
      ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

      salesforce_error =
        %([{"message":"Required fields are missing: [Subject]","errorCode":"REQUIRED_FIELD_MISSING"}])

      stub_request(:post, "#{api_path}/Case").to_return(
        status: 400,
        body: salesforce_error,
        headers: {
        },
      )

      post "/salesforce/cases/sync.json", params: { topic_id: topic.id }

      expect(response.status).to eq(422)
      expect(response.parsed_body).to eq({ "errors" => [salesforce_error] })
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
