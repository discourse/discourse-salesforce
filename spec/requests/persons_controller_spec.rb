# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::PersonsController do
  include_context "with salesforce spec helper"

  fab!(:user)
  fab!(:admin)

  describe "#unlink_contact" do
    fab!(:sync_post) { Fabricate(:post, user: user) }
    let(:params) do
      { user_id: user.id, post_id: sync_post.id, expected_contact_id: "invalid-contact-id" }
    end

    before do
      SiteSetting.salesforce_contact_unlink_allowed_groups = "admins"
      user.upsert_custom_fields(Salesforce::Contact::ID_FIELD => params[:expected_contact_id])
    end

    it "rejects anonymous users, ordinary users and unselected moderators" do
      delete "/salesforce/persons/contact.json", params: params
      expect(response.status).to eq(403)

      [user, Fabricate(:moderator)].each do |non_admin|
        sign_in(non_admin)
        delete "/salesforce/persons/contact.json", params: params
        expect(response.status).to eq(403)
      end
      expect(user.reload.salesforce_contact_id).to eq(params[:expected_contact_id])
    end

    it "allows selected moderators, while unselected staff and an empty setting are denied" do
      moderator = Fabricate(:moderator)
      sign_in(moderator)
      SiteSetting.salesforce_contact_unlink_allowed_groups = "moderators"
      delete "/salesforce/persons/contact.json", params: params
      expect(response.status).to eq(204)

      user.upsert_custom_fields(Salesforce::Contact::ID_FIELD => params[:expected_contact_id])
      SiteSetting.salesforce_contact_unlink_allowed_groups = "admins"
      delete "/salesforce/persons/contact.json", params: params
      expect(response.status).to eq(403)

      admin.update!(last_seen_at: 1.hour.ago)
      sign_in(admin)
      SiteSetting.salesforce_contact_unlink_allowed_groups = "moderators"
      delete "/salesforce/persons/contact.json", params: params
      expect(response.status).to eq(403)

      SiteSetting.salesforce_contact_unlink_allowed_groups = ""
      SiteSetting.salesforce_case_unlink_allowed_groups = "admins"
      delete "/salesforce/persons/contact.json", params: params
      expect(response.status).to eq(403)
      expect(user.reload.salesforce_contact_id).to eq(params[:expected_contact_id])

      SiteSetting.salesforce_contact_unlink_allowed_groups = "admins"
      SiteSetting.salesforce_case_unlink_allowed_groups = ""
      delete "/salesforce/persons/contact.json", params: params
      expect(response.status).to eq(204)
      expect(user.reload.salesforce_contact_id).to be_nil

      salesforce_case = Fabricate(:salesforce_case, topic: sync_post.topic)
      delete "/salesforce/cases/#{salesforce_case.id}.json"
      expect(response.status).to eq(403)
      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
    end

    it "requires a visible post even for a permitted moderator" do
      sign_in(Fabricate(:moderator))
      SiteSetting.salesforce_contact_unlink_allowed_groups = "moderators"
      private_post = Fabricate(:private_message_post, user: user)
      delete "/salesforce/persons/contact.json", params: params.merge(post_id: private_post.id)
      expect(response.status).to eq(403)
      expect(user.reload.salesforce_contact_id).to eq(params[:expected_contact_id])
    end

    it "unlinks malformed stored IDs and publishes the cleared field only to staff" do
      sign_in(admin)
      sync_post = Fabricate(:post, user: user)
      messages =
        MessageBus.track_publish("/topic/#{sync_post.topic_id}") do
          delete "/salesforce/persons/contact.json", params: params.merge(post_id: sync_post.id)
        end

      expect(response.status).to eq(204)
      expect(user.reload.salesforce_contact_id).to be_nil
      expect(messages.map(&:data)).to eq(
        [
          {
            type: "salesforce_person_synced",
            user_id: user.id,
            field: "salesforce_contact_id",
            value: nil,
            expected_value: params[:expected_contact_id],
          },
        ],
      )
      expect(messages.first.group_ids).to contain_exactly(
        Group::AUTO_GROUPS[:admins],
        Group::AUTO_GROUPS[:moderators],
      )
      expect(a_request(:any, /salesforce\.com/)).not_to have_been_made

      messages =
        MessageBus.track_publish("/topic/#{sync_post.topic_id}") do
          delete "/salesforce/persons/contact.json", params: params.merge(post_id: sync_post.id)
        end
      expect(response.status).to eq(204)
      expect(messages).to be_empty
    end

    it "requires the expected ID and validates post ownership before unlinking" do
      sign_in(admin)
      delete "/salesforce/persons/contact.json", params: params.except(:expected_contact_id)
      expect(response.status).to eq(400)

      delete "/salesforce/persons/contact.json", params: params.except(:post_id)
      expect(response.status).to eq(400)

      other_post = Fabricate(:post)
      delete "/salesforce/persons/contact.json", params: params.merge(post_id: other_post.id)
      expect(response.status).to eq(400)
      expect(user.reload.salesforce_contact_id).to eq(params[:expected_contact_id])
    end

    it "returns a conflict when either stored association differs from the displayed ID" do
      sign_in(admin)
      delete "/salesforce/persons/contact.json",
             params: params.merge(expected_contact_id: "older-id")

      expect(response.status).to eq(409)
      expect(response.parsed_body["errors"]).to eq(
        [I18n.t("salesforce.error.contact_link_changed")],
      )
      expect(user.reload.salesforce_contact_id).to eq(params[:expected_contact_id])

      guided_link =
        Salesforce::RecordLink.link!(
          provider: "salesforce",
          account: instance_url,
          object: "Contact",
          user_id: user.id,
          external_id: "newer-guided-id",
        )

      delete "/salesforce/persons/contact.json", params: params

      expect(response.status).to eq(409)
      expect(response.parsed_body["errors"]).to eq(
        [I18n.t("salesforce.error.contact_link_changed")],
      )
      expect(user.reload.salesforce_contact_id).to eq(params[:expected_contact_id])
      expect(guided_link.reload.external_id).to eq("newer-guided-id")
    end
  end

  describe "#create" do
    before do
      sign_in(admin)
      Salesforce.seed_groups!
    end

    it "creates a new contact object in Salesforce when Leads are disabled" do
      SiteSetting.salesforce_leads_enabled = false
      sync_post = Fabricate(:post, user: user)

      stub_salesforce_person_lookup("Contact", user.email)

      stub_request(:post, "#{api_path}/Contact").with(
        body: user.salesforce_contact_payload.to_json,
      ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

      messages =
        MessageBus.track_publish("/topic/#{sync_post.topic_id}") do
          post "/salesforce/persons/create.json",
               params: {
                 type: "contact",
                 user_id: user.id,
                 post_id: sync_post.id,
               }
        end

      expect(response.status).to eq(200)
      expect(user.salesforce_contact_id).to eq("123456")
      expect(messages.size).to eq(1)
      expect(messages.first.data).to eq(
        type: "salesforce_person_synced",
        user_id: user.id,
        field: "salesforce_contact_id",
        value: "123456",
      )
      expect(messages.first.group_ids).to eq([Group::AUTO_GROUPS[:admins]])
    end

    it "links an existing contact by email and syncs its configured fields" do
      existing_user =
        Fabricate(:verified_user, email: "team+salesforce-discourse-dev-ed@example.com")
      existing_contact_id = "123456"
      SiteSetting.salesforce_contact_sync_mode = "fill_blank"

      stub_salesforce_person_lookup(
        "Contact",
        existing_user.email,
        fields: %i[Description],
        record: {
          Id: existing_contact_id,
          Description: nil,
        },
      )
      patch_request =
        stub_request(:patch, "#{api_path}/Contact/#{existing_contact_id}").with(
          body: { Description: "http://test.localhost/u/#{existing_user.username}" }.to_json,
        ).to_return(status: 204)

      post "/salesforce/persons/create.json", params: { type: "contact", user_id: existing_user.id }

      expect(response.status).to eq(200)
      expect(existing_user.reload.salesforce_contact_id).to eq(existing_contact_id)
      expect(Salesforce.contacts_group.users.exists?(existing_user.id)).to eq(true)
      expect(a_request(:post, "#{api_path}/Contact")).not_to have_been_made
      expect(patch_request).to have_been_requested
    end

    it "does not publish a topic update without a post" do
      stub_salesforce_person_lookup("Contact", user.email)

      stub_request(:post, "#{api_path}/Contact").with(
        body: user.salesforce_contact_payload.to_json,
      ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

      messages =
        MessageBus.track_publish do
          post "/salesforce/persons/create.json", params: { type: "contact", user_id: user.id }
        end

      expect(response.status).to eq(200)
      expect(messages.map(&:channel)).not_to include(a_string_matching(%r{\A/topic/}))
    end

    it "creates a new lead object in Salesforce" do
      stub_salesforce_converted_lead_lookup(user.email)
      stub_salesforce_person_lookup("Lead", user.email)

      stub_request(:post, "#{api_path}/Lead").with(
        body: user.salesforce_lead_payload.to_json,
      ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

      post "/salesforce/persons/create.json", params: { type: "lead", user_id: user.id }

      expect(response.status).to eq(200)
      expect(user.salesforce_lead_id).to eq("123456")
    end

    it "rejects Lead creation when Leads are disabled" do
      SiteSetting.salesforce_leads_enabled = false
      post "/salesforce/persons/create.json", params: { type: "lead", user_id: user.id }

      expect(response.status).to eq(400)
      expect(user.reload.salesforce_lead_id).to be_nil
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end
  end
end
