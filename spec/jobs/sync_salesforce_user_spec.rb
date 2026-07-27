# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::SyncSalesforceUser do
  include_context "with salesforce spec helper"

  fab!(:user) do
    Fabricate(
      :user,
      email: "person@example.com",
      name: "Example Person",
      username: "example_person",
    )
  end

  it "links an existing contact by default" do
    stub_salesforce_person_lookup("Contact", user.email, id: "contact_123")

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to eq("contact_123")
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "keeps first-match linking for duplicate records in link-only mode" do
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      records: [{ Id: "contact_123" }, { Id: "contact_456" }],
    )

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to eq("contact_123")
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "falls back to a lead without updating it" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    stub_salesforce_person_lookup("Contact", user.email, fields: %i[Description])
    stub_salesforce_person_lookup("Lead", user.email, id: "lead_123")

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_lead_id).to eq("lead_123")
    expect(a_request(:patch, %r{/sobjects/Lead/})).not_to have_been_made
  end

  it "fills a blank description when updating existing users is enabled" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[Description],
      record: {
        Id: "contact_123",
        Description: nil,
      },
    )
    patch_request =
      stub_request(:patch, "#{api_path}/Contact/contact_123").with(
        body: { Description: "http://test.localhost/u/example_person" }.to_json,
      ).to_return(status: 204)

    described_class.new.execute(user_id: user.id)

    expect(patch_request).to have_been_requested
  end

  it "does not update Salesforce when the description is populated" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[Description],
      record: {
        Id: "contact_123",
        Description: "Existing notes",
      },
    )

    described_class.new.execute(user_id: user.id)

    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "overwrites the description when overwrite mode is enabled" do
    SiteSetting.salesforce_existing_record_sync_mode = "overwrite"
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[Description],
      record: {
        Id: "contact_123",
        Description: "Existing notes",
      },
    )
    patch_request =
      stub_request(:patch, "#{api_path}/Contact/contact_123").with(
        body: { Description: "http://test.localhost/u/example_person" }.to_json,
      ).to_return(status: 204)

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to eq("contact_123")
    expect(patch_request).to have_been_requested
  end

  it "skips ambiguous records when field synchronization is enabled" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[Description],
      records: [{ Id: "contact_123", Description: nil }, { Id: "contact_456", Description: nil }],
    )

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to be_nil
    expect(user.salesforce_lead_id).to be_nil
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end
end
