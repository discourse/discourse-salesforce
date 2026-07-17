# frozen_string_literal: true

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

    it "links an existing contact in Salesforce by email" do
      existing_user = Fabricate(:user, email: "team+salesforce-discourse-dev-ed@example.com")
      existing_contact_id = "123456"

      stub_salesforce_person_lookup("Contact", existing_user.email, id: existing_contact_id)

      post "/salesforce/persons/create.json", params: { type: "contact", user_id: existing_user.id }

      expect(response.status).to eq(200)
      expect(existing_user.reload.salesforce_contact_id).to eq(existing_contact_id)
      expect(Salesforce.contacts_group.users.exists?(existing_user.id)).to eq(true)
      expect(a_request(:post, "#{api_path}/Contact")).not_to have_been_made
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
      stub_salesforce_person_lookup("Lead", user.email)

      stub_request(:post, "#{api_path}/Lead").with(
        body: user.salesforce_lead_payload.to_json,
      ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

      post "/salesforce/persons/create.json", params: { type: "lead", user_id: user.id }

      expect(response.status).to eq(200)
      expect(user.salesforce_lead_id).to eq("123456")
    end
  end
end
