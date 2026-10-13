# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "syncing users created through DiscourseConnect" do
  include_context "with salesforce spec helper"

  before do
    Jobs.run_immediately!
    SiteSetting.discourse_connect_url = "http://example.com/sso"
    SiteSetting.discourse_connect_secret = "supersecret"
    SiteSetting.enable_discourse_connect = true
    SiteSetting.salesforce_contact_sync_mode = "overwrite"
    SiteSetting.salesforce_contact_sync_fields = "FirstName"
  end

  it "syncs a new user with the configured mode" do
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
        body: { FirstName: "Connected" }.to_json,
      ).to_return(status: 204)

    sso = DiscourseConnect.new(server_session: ServerSession.new("sso"))
    sso.external_id = "external_123"
    sso.email = email
    sso.username = "connected_user"
    sso.name = "Connected User"
    user = sso.lookup_or_create_user

    expect(user).to be_active
    expect(user.salesforce_contact_id).to eq("contact_123")
    expect(patch_request).to have_been_requested
  end
end
