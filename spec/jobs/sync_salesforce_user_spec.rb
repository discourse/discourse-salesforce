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

  let(:plugin_instance) { Plugin::Instance.new }
  let(:modifier_block) do
    Proc.new { |payload, _user, _object_name| payload.merge(CustomField__c: "Custom value") }
  end

  after do
    @registered_modifiers&.each do |registered_modifier|
      DiscoursePluginRegistry.unregister_modifier(
        plugin_instance,
        :salesforce_existing_user_sync_payload,
        &registered_modifier
      )
    end
  end

  it "links an existing contact without applying the modifier by default" do
    register_sync_modifier
    stub_salesforce_person_lookup("Contact", user.email, id: "contact_123")

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to eq("contact_123")
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "keeps first-match linking for duplicate records when synchronization is disabled" do
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      records: [{ Id: "contact_123" }, { Id: "contact_456" }],
    )

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to eq("contact_123")
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "applies the payload modifier when updating existing users is enabled" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    register_sync_modifier
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[LeadSource Description CustomField__c],
      record: {
        Id: "contact_123",
        LeadSource: "Referral",
        Description: "Existing notes",
        CustomField__c: nil,
      },
    )
    patch_request =
      stub_request(:patch, "#{api_path}/Contact/contact_123").with(
        body: { CustomField__c: "Custom value" }.to_json,
      ).to_return(status: 204)

    described_class.new.execute(user_id: user.id)

    expect(patch_request).to have_been_requested
  end

  it "falls back to a lead and fills its blank selected fields" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    fields = %i[LeadSource Description]
    stub_salesforce_person_lookup("Contact", user.email, fields: fields)
    stub_salesforce_person_lookup(
      "Lead",
      user.email,
      fields: fields,
      record: {
        Id: "lead_123",
        LeadSource: nil,
        Description: "Existing notes",
      },
    )
    patch_request =
      stub_request(:patch, "#{api_path}/Lead/lead_123").with(
        body: { LeadSource: "Web" }.to_json,
      ).to_return(status: 204)

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_lead_id).to eq("lead_123")
    expect(patch_request).to have_been_requested
  end

  it "fills only blank fields when updating existing users is enabled" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[LeadSource Description],
      record: {
        Id: "contact_123",
        LeadSource: "Referral",
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

  it "does not update Salesforce when every selected field is populated" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[LeadSource Description],
      record: {
        Id: "contact_123",
        LeadSource: "Referral",
        Description: "Existing notes",
      },
    )

    described_class.new.execute(user_id: user.id)

    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "overwrites selected fields when overwrite mode is enabled" do
    SiteSetting.salesforce_existing_record_sync_mode = "overwrite"
    register_sync_modifier
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[LeadSource Description CustomField__c],
      record: {
        Id: "contact_123",
        LeadSource: "Referral",
        Description: "Existing notes",
        CustomField__c: "Existing custom value",
      },
    )
    patch_request =
      stub_request(:patch, "#{api_path}/Contact/contact_123").with(
        body: {
          LeadSource: "Web",
          Description: "http://test.localhost/u/example_person",
          CustomField__c: "Custom value",
        }.to_json,
      ).to_return(status: 204)

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to eq("contact_123")
    expect(patch_request).to have_been_requested
  end

  it "does not clear fields with empty modifier values in overwrite mode" do
    SiteSetting.salesforce_existing_record_sync_mode = "overwrite"
    empty_modifier =
      Proc.new { |payload, _user, _object_name| payload.merge(LeadSource: nil, Description: "") }
    register_sync_modifier(empty_modifier)
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[LeadSource Description],
      record: {
        Id: "contact_123",
        LeadSource: "Referral",
        Description: "Existing notes",
      },
    )

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to eq("contact_123")
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  it "skips ambiguous records when field synchronization is enabled" do
    SiteSetting.salesforce_existing_record_sync_mode = "fill_blank"
    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %i[LeadSource Description],
      records: [
        { Id: "contact_123", LeadSource: nil, Description: nil },
        { Id: "contact_456", LeadSource: nil, Description: nil },
      ],
    )

    described_class.new.execute(user_id: user.id)

    expect(user.reload.salesforce_contact_id).to be_nil
    expect(user.salesforce_lead_id).to be_nil
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end

  private

  def register_sync_modifier(sync_modifier = modifier_block)
    plugin_instance.register_modifier(:salesforce_existing_user_sync_payload, &sync_modifier)
    (@registered_modifiers ||= []) << sync_modifier
  end
end
