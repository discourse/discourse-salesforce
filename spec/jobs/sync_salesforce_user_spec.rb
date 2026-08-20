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

  it "preserves ID-only lead linking when no contact exists" do
    SiteSetting.salesforce_contact_sync_mode = "fill_blank"
    stub_salesforce_person_lookup("Contact", user.email, fields: %i[Description])
    stub_salesforce_person_lookup("Lead", user.email, id: "lead_123")

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_lead_id).to eq("lead_123")
  end

  it "fills a blank description when updating existing users is enabled" do
    SiteSetting.salesforce_contact_sync_mode = "fill_blank"
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
    SiteSetting.salesforce_contact_sync_mode = "fill_blank"
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

  it "overwrites configured fields when overwrite mode is enabled" do
    SiteSetting.salesforce_contact_sync_mode = "overwrite"
    SiteSetting.salesforce_contact_sync_fields = "FirstName"
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[FirstName],
      record: {
        Id: "contact_123",
        FirstName: "Old name",
      },
    )
    patch_request =
      stub_request(:patch, "#{api_path}/Contact/contact_123").with(
        body: { FirstName: "Example" }.to_json,
      ).to_return(status: 204)

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to eq("contact_123")
    expect(patch_request).to have_been_requested
  end

  it "creates nothing when no contact or lead matches by default" do
    stub_salesforce_person_lookup("Contact", user.email)
    stub_salesforce_person_lookup("Lead", user.email)

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to be_nil
    expect(user.salesforce_lead_id).to be_nil
    expect(a_request(:post, %r{/sobjects/})).not_to have_been_made
  end

  context "when salesforce_contact_auto_create_on_signup is enabled" do
    before do
      SiteSetting.salesforce_contact_auto_create_on_signup = true
      Salesforce.seed_groups!
      stub_salesforce_person_lookup("Contact", user.email)
      stub_salesforce_person_lookup("Lead", user.email)
    end

    it "creates a contact when no contact or lead matches" do
      create_request =
        stub_request(:post, "#{api_path}/Contact").with(
          body: user.salesforce_contact_payload.to_json,
        ).to_return(status: 200, body: %({"id":"contact_new"}))

      described_class.new.execute(user_id: user.id)

      expect(create_request).to have_been_requested
      expect(user.reload.salesforce_contact_id).to eq("contact_new")
      expect(Salesforce.contacts_group.users.exists?(user.id)).to eq(true)
    end

    it "links a matching lead instead of creating a contact" do
      stub_salesforce_person_lookup("Lead", user.email, id: "lead_123")

      described_class.new.execute(user_id: user.id)

      expect(user.reload.salesforce_lead_id).to eq("lead_123")
      expect(a_request(:post, %r{/sobjects/})).not_to have_been_made
    end

    it "waits for the user to become active" do
      user.update!(active: false)

      described_class.new.execute(user_id: user.id)

      expect(user.reload.salesforce_contact_id).to be_nil
      expect(a_request(:post, %r{/sobjects/})).not_to have_been_made
    end

    it "does not create contacts for staged users" do
      user.update!(staged: true)

      described_class.new.execute(user_id: user.id)

      expect(a_request(:post, %r{/sobjects/})).not_to have_been_made
    end

    it "does not create contacts for suspended users" do
      user.update!(suspended_at: Time.zone.now, suspended_till: 1.year.from_now)

      described_class.new.execute(user_id: user.id)

      expect(a_request(:post, %r{/sobjects/})).not_to have_been_made
    end

    it "logs instead of raising when Salesforce rejects the contact" do
      stub_request(:post, "#{api_path}/Contact").to_return(
        status: 400,
        body: %([{"errorCode":"DUPLICATES_DETECTED","message":"Use one of these records?"}]),
      )

      expect { described_class.new.execute(user_id: user.id) }.not_to raise_error
      expect(user.reload.salesforce_contact_id).to be_nil
    end

    it "logs instead of raising when Salesforce cannot find the endpoint" do
      stub_request(:post, "#{api_path}/Contact").to_return(
        status: 404,
        body: %([{"errorCode":"NOT_FOUND","message":"The requested resource does not exist"}]),
      )

      expect { described_class.new.execute(user_id: user.id) }.not_to raise_error
    end

    it "raises for transient Salesforce failures so the job retries" do
      stub_request(:post, "#{api_path}/Contact").to_return(status: 503, body: "")

      expect { described_class.new.execute(user_id: user.id) }.to raise_error(
        Salesforce::InvalidApiResponse,
      )
    end
  end

  it "skips ambiguous records when field synchronization is enabled" do
    SiteSetting.salesforce_contact_sync_mode = "fill_blank"
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
