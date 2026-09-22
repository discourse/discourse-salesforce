# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe UsersController do
  include_context "with salesforce spec helper"

  describe "#create" do
    before do
      Jobs.run_immediately!
      UsersController.any_instance.stubs(:honeypot_or_challenge_fails?).returns(false)
      SiteSetting.salesforce_contact_sync_mode = "overwrite"
      SiteSetting.salesforce_contact_sync_fields = "FirstName"
    end

    it "links a matching contact at signup and only updates it after the email is confirmed" do
      email = "contact-owner@example.com"
      stub_salesforce_person_lookup("Contact", email, id: "contact_123")
      stub_salesforce_person_lookup(
        "Contact",
        email,
        fields: %i[FirstName],
        record: {
          Id: "contact_123",
          FirstName: "Contact owner",
        },
      )
      patch_request =
        stub_request(:patch, "#{api_path}/Contact/contact_123").with(
          body: { FirstName: "New" }.to_json,
        ).to_return(status: 204)

      post "/u.json",
           params: {
             name: "New Name",
             username: "new_account",
             password: "strongpassword",
             email: email,
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include("success" => true, "active" => false)

      user = User.find_by!(username: "new_account")
      expect(user.salesforce_contact_id).to eq("contact_123")
      expect(patch_request).not_to have_been_requested

      email_token = Fabricate(:email_token, user: user)
      put "/u/activate-account/#{email_token.token}"

      expect(response.status).to eq(200)
      expect(user.reload).to be_active
      expect(patch_request).to have_been_requested
    end
  end
end
