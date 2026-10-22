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

  describe "#destroy" do
    fab!(:salesforce_case) { Fabricate(:salesforce_case, topic: topic) }

    before { topic.upsert_custom_fields(::CaseMixin::HAS_SALESFORCE_CASE => true) }

    it "disables unlinking for admins and moderators when no groups are selected" do
      [admin, moderator].each do |user|
        sign_in(user)

        delete "/salesforce/cases/#{salesforce_case.id}.json"

        expect(response.status).to eq(403)
        expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
      end
    end

    %i[admins moderators].each do |group_name|
      it "allows members of the selected #{group_name} group to unlink cases" do
        SiteSetting.salesforce_case_unlink_allowed_groups = group_name.to_s
        sign_in(group_name == :admins ? admin : moderator)

        delete "/salesforce/cases/#{salesforce_case.id}.json"

        expect(response.status).to eq(204)
        expect(response.body).to be_empty
        expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(false)
      end
    end

    it "denies regular users when both staff groups are selected" do
      SiteSetting.salesforce_case_unlink_allowed_groups = "admins|moderators"
      sign_in(topic.user)

      get "/t/#{topic.id}.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body["can_unlink_salesforce_case"]).to eq(false)
      expect(response.parsed_body).not_to have_key("salesforce_case")

      delete "/salesforce/cases/#{salesforce_case.id}.json"

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
    end

    it "denies admins without the moderator role when only moderators are selected" do
      SiteSetting.salesforce_case_unlink_allowed_groups = "moderators"
      admin.update!(last_seen_at: 1.hour.ago)
      sign_in(admin)

      delete "/salesforce/cases/#{salesforce_case.id}.json"

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
    end

    it "denies moderators when only admins are selected" do
      SiteSetting.salesforce_case_unlink_allowed_groups = "admins"
      sign_in(moderator)

      delete "/salesforce/cases/#{salesforce_case.id}.json"

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
    end

    it "allows both staff roles when both are selected" do
      SiteSetting.salesforce_case_unlink_allowed_groups = "admins|moderators"
      other_case = Fabricate(:salesforce_case)

      [[admin, salesforce_case], [moderator, other_case]].each do |user, linked_case|
        sign_in(user)

        delete "/salesforce/cases/#{linked_case.id}.json"

        expect(response.status).to eq(204)
        expect(Salesforce::Case.exists?(linked_case.id)).to eq(false)
      end
    end

    it "requires login" do
      SiteSetting.salesforce_case_unlink_allowed_groups = "admins|moderators"

      delete "/salesforce/cases/#{salesforce_case.id}.json"

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
    end

    it "denies members access to private topics they cannot see" do
      SiteSetting.salesforce_case_unlink_allowed_groups = "moderators"
      private_case = Fabricate(:salesforce_case, topic: Fabricate(:private_message_topic))
      sign_in(moderator)

      delete "/salesforce/cases/#{private_case.id}.json"

      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(private_case.id)).to eq(true)
    end

    it "returns 404 for a missing case" do
      SiteSetting.salesforce_case_unlink_allowed_groups = "admins"
      sign_in(admin)

      delete "/salesforce/cases/0.json"

      expect(response.status).to eq(404)
    end

    it "unlinks locally even when Salesforce credentials are unavailable" do
      SiteSetting.salesforce_case_unlink_allowed_groups = "admins"
      SiteSetting.salesforce_client_id = ""
      sign_in(admin)

      delete "/salesforce/cases/#{salesforce_case.id}.json"

      expect(response.status).to eq(204)
      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(false)
      expect(topic.reload.has_salesforce_case).to eq(false)
      expect(a_request(:any, %r{https://test\.my\.salesforce\.com/})).not_to have_been_made
      expect(
        a_request(:post, "https://login.salesforce.com/services/oauth2/token"),
      ).not_to have_been_made
    end
  end
end
