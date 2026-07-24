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
    if @modifier_registered
      DiscoursePluginRegistry.unregister_modifier(
        plugin_instance,
        :salesforce_existing_user_sync_payload,
        &modifier_block
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

  it "applies the payload modifier when updating existing users is enabled" do
    SiteSetting.salesforce_fill_blank_fields_on_user_sync = true
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
    SiteSetting.salesforce_fill_blank_fields_on_user_sync = true
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
    SiteSetting.salesforce_fill_blank_fields_on_user_sync = true
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
    SiteSetting.salesforce_fill_blank_fields_on_user_sync = true
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

  private

  def register_sync_modifier
    plugin_instance.register_modifier(:salesforce_existing_user_sync_payload, &modifier_block)
    @modifier_registered = true
  end
end
