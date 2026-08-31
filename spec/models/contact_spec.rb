# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::Contact do
  include_context "with salesforce spec helper"

  describe ".payload" do
    fab!(:user)

    let(:plugin_instance) { Plugin::Instance.new }
    let(:modifier_block) do
      Proc.new { |default_payload, _| default_payload.merge(CustomField__c: "Custom Value") }
    end

    before { plugin_instance.register_modifier(:salesforce_contact_payload, &modifier_block) }

    after do
      DiscoursePluginRegistry.unregister_modifier(
        plugin_instance,
        :salesforce_contact_payload,
        &modifier_block
      )
    end

    it "applies the salesforce_contact_payload modifier" do
      expect(described_class.payload(user)).to eq(
        user.salesforce_contact_payload.merge(CustomField__c: "Custom Value"),
      )
    end
  end

  describe ".sync" do
    fab!(:user)

    let(:plugin_instance) { Plugin::Instance.new }
    let(:modifier_block) do
      Proc.new do |fields, sync_payload, record|
        fields.merge(Description: "#{record["Description"]}\n\n#{sync_payload[:Description]}")
      end
    end

    before do
      SiteSetting.salesforce_contact_sync_mode = "fill_blank"
      plugin_instance.register_modifier(:salesforce_person_sync_fields, &modifier_block)
    end

    after do
      DiscoursePluginRegistry.unregister_modifier(
        plugin_instance,
        :salesforce_person_sync_fields,
        &modifier_block
      )
    end

    it "applies the salesforce_person_sync_fields modifier before updating the record" do
      stub_salesforce_person_lookup(
        "Contact",
        user.email,
        record: {
          Id: "123456",
          Description: "Old description",
        },
        fields: [:Description],
      )

      update_contact =
        stub_request(:patch, "#{api_path}/Contact/123456").with(
          body: {
            Description: "Old description\n\n#{user.salesforce_contact_payload[:Description]}",
          },
        ).to_return(status: 204, body: "")

      expect(described_class.sync(user)).to eq(true)
      expect(update_contact).to have_been_requested
      expect(user.reload.salesforce_contact_id).to eq("123456")
    end
  end

  describe ".find_id_by_email" do
    it "escapes SOQL string values before querying by email" do
      email = "team+salesforce.o'hara@example.com"
      contact_id = "123456"

      stub_request(:get, query_path).with(
        query: {
          q: "SELECT Id FROM Contact WHERE Email = 'team+salesforce.o\\'hara@example.com'",
        },
      ).to_return(
        status: 200,
        body: { totalSize: 1, records: [{ Id: contact_id }] }.to_json,
        headers: {
        },
      )

      expect(described_class.find_id_by_email(email)).to eq(contact_id)
    end

    it "keeps linking existing contacts after looking up additional fields" do
      email = "existing@example.com"
      stub_salesforce_person_lookup(
        "Contact",
        email,
        fields: [:LeadSource],
        record: {
          Id: "123456",
          LeadSource: "Referral",
        },
      )

      expect(described_class.find_by_email(email, fields: [:LeadSource])).to eq(
        { "Id" => "123456", "LeadSource" => "Referral" },
      )
    end

    it "rejects invalid projected field names" do
      expect do
        described_class.find_by_email("person@example.com", fields: ["Id FROM Lead"])
      end.to raise_error(ArgumentError, "Invalid Salesforce field name: Id FROM Lead")
    end

    it "rejects ambiguous email matches when uniqueness is required" do
      email = "duplicate@example.com"
      stub_salesforce_person_lookup("Contact", email, records: [{ Id: "123456" }, { Id: "654321" }])

      expect do described_class.find_by_email(email, require_unique: true) end.to raise_error(
        Salesforce::AmbiguousEmailMatch,
        "Multiple Salesforce Contact records have the same email",
      )
    end
  end
end
