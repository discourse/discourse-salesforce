# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::SyncSalesforceUsers do
  include_context "with salesforce spec helper"

  fab!(:user1, :user)
  fab!(:user2, :user)
  let!(:path) { api_path.sub("sobjects", "composite/sobjects") }

  before do
    Salesforce.seed_groups!
    Salesforce.leads_group.add(user1)
  end

  describe "#execute" do
    it "continues syncing contact merges after a missing contact" do
      user1.salesforce_contact_id = "missing_contact"
      user1.save_custom_fields
      user2.salesforce_contact_id = "contact_123"
      user2.save_custom_fields
      PluginStore.set(
        Salesforce::PLUGIN_NAME,
        "configured_user_link:Contact:#{user2.id}",
        { id: "contact_123", instance: "another-account" },
      )

      stub_request(
        :get,
        "#{path}/Contact?fields=MasterRecordId&ids=missing_contact,contact_123",
      ).to_return(
        status: 200,
        body: [nil, { Id: "contact_123", MasterRecordId: "contact_456" }].to_json,
      )

      described_class.new.execute({})

      expect(user1.reload.salesforce_contact_id).to eq("missing_contact")
      expect(user2.reload.salesforce_contact_id).to eq("contact_456")
      link =
        Salesforce::RecordLink.new(
          provider: "salesforce",
          account: instance_url,
          object: "Contact",
          user_id: user2.id,
        )
      expect(link.read).to eq("id" => "contact_123", "account" => "another-account")
    end

    it "continues syncing lead conversions after a missing lead" do
      user1.salesforce_lead_id = "missing_lead"
      user1.save_custom_fields
      user2.salesforce_lead_id = "lead_123"
      user2.save_custom_fields

      stub_request(
        :get,
        "#{path}/Lead?fields=ConvertedContactId&ids=missing_lead,lead_123",
      ).to_return(
        status: 200,
        body: [nil, { Id: "lead_123", ConvertedContactId: "contact_456" }].to_json,
      )
      stub_request(:get, "#{path}/Contact?fields=MasterRecordId&ids=contact_456").to_return(
        status: 200,
        body: [{ Id: "contact_456", MasterRecordId: nil }].to_json,
      )

      described_class.new.execute({})

      expect(user1.reload.salesforce_lead_id).to eq("missing_lead")
      expect(user1.salesforce_contact_id).to be_nil
      expect(user2.reload.salesforce_lead_id).to be_nil
      expect(user2.salesforce_contact_id).to eq("contact_456")
      expect(
        Salesforce::RecordLink.new(
          provider: "salesforce",
          account: instance_url,
          object: "Lead",
          user_id: user2.id,
        ).read,
      ).to include("converted_to" => { "object" => "Contact", "id" => "contact_456" })
    end

    it "rolls back the custom field if persisting a configured link fails" do
      user2.salesforce_contact_id = "contact_123"
      user2.save_custom_fields
      SiteSetting.salesforce_instance_url = instance_url
      link =
        Salesforce::RecordLink.new(
          provider: "salesforce",
          account: instance_url,
          object: "Contact",
          user_id: user2.id,
        )
      link.write("contact_123")
      stub_request(:get, "#{path}/Contact?fields=MasterRecordId&ids=contact_123").to_return(
        body: [{ Id: "contact_123", MasterRecordId: "contact_456" }].to_json,
      )
      PluginStore.stubs(:set).raises(ActiveRecord::StatementInvalid)

      described_class.new.execute({})

      expect(user2.reload.salesforce_contact_id).to eq("contact_123")
      expect(link.read["id"]).to eq("contact_123")
    end

    it "skips existing Lead links when Leads are disabled" do
      SiteSetting.salesforce_leads_enabled = false
      Salesforce.leads_group.users.clear
      user1.salesforce_lead_id = "lead_123"
      user1.save_custom_fields

      described_class.new.execute({})

      expect(user1.reload.salesforce_lead_id).to eq("lead_123")
      expect(a_request(:get, %r{/composite/sobjects/Lead})).not_to have_been_made
    end
  end

  describe "proper leads and contacts in response" do
    before do
      user1.salesforce_lead_id = "lead_123"
      user1.save!

      user2.salesforce_contact_id = "contact_123"
      user2.save!

      stub_request(:get, "#{path}/Lead?fields=ConvertedContactId&ids=lead_123").to_return(
        status: 200,
        body: [{ ConvertedContactId: "contact_456", Id: "lead_123" }].to_json,
      )
      stub_request(
        :get,
        "#{path}/Contact?fields=MasterRecordId&ids=contact_456,contact_123",
      ).to_return(status: 200, body: [{ MasterRecordId: "contact_789", Id: "contact_123" }].to_json)
    end

    it "syncs lead to contact conversions and contact merges from Salesforce" do
      lead_link =
        Salesforce::RecordLink.new(
          provider: "salesforce",
          account: instance_url,
          object: "Lead",
          user_id: user1.id,
        )
      contact_link =
        Salesforce::RecordLink.new(
          provider: "salesforce",
          account: instance_url,
          object: "Contact",
          user_id: user2.id,
        )
      lead_link.write("lead_123")
      contact_link.write("contact_123")
      described_class.new.execute({})

      expect(lead_link.read).to eq(
        "account" => instance_url,
        "converted_to" => {
          "object" => "Contact",
          "id" => "contact_456",
        },
      )
      expect(contact_link.read["id"]).to eq("contact_789")
      expect(
        Salesforce::RecordLink.new(
          provider: "salesforce",
          account: instance_url,
          object: "Contact",
          user_id: user1.id,
        ).read,
      ).to include("id" => "contact_456", "converted_from_lead_id" => "lead_123")
      expect(
        Salesforce::RecordLink.new(
          provider: "salesforce",
          account: instance_url,
          object: "Contact",
          user_id: user1.id,
        ).read[
          "id"
        ],
      ).to eq("contact_456")
      fields = user1.reload.custom_fields
      expect(fields[::Salesforce::Lead::ID_FIELD]).to eq(nil)
      expect(fields[::Salesforce::Contact::ID_FIELD]).to eq("contact_456")

      expect(user2.reload.salesforce_contact_id).to eq("contact_789")
    end
  end

  describe "bad response" do
    it "does not fail the job" do
      stub_request(
        :post,
        "#{SiteSetting.salesforce_authorization_server_url}/services/oauth2/token",
      ).to_return(status: 400)

      expect { described_class.new.execute({}) }.not_to raise_error
    end
  end
end
