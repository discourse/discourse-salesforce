# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::Lead do
  include_context "with salesforce spec helper"

  fab!(:user)

  describe ".sync" do
    it "preserves a different legacy Lead association during conversion reconciliation" do
      user.upsert_custom_fields(Salesforce::Lead::ID_FIELD => "live-lead")
      stub_salesforce_person_lookup("Lead", user.email)
      stub_salesforce_converted_lead_lookup(
        user.email,
        records: [{ Id: "converted-lead", IsConverted: true, ConvertedContactId: "contact1" }],
      )

      expect(described_class.sync(user)).to eq(true)

      expect(user.reload.salesforce_lead_id).to eq("live-lead")
      expect(user.salesforce_contact_id).to be_nil
      scope = { provider: "salesforce", account: instance_url, user_id: user.id }
      expect(Salesforce::RecordLink.find_by(**scope, object: "Lead")).to be_nil
      expect(Salesforce::RecordLink.find_by(**scope, object: "Contact")).to be_nil
    end
  end

  describe ".create!" do
    before { stub_salesforce_converted_lead_lookup(user.email) }

    it "skips creation when Leads are disabled and the group is missing" do
      SiteSetting.salesforce_leads_enabled = false
      SiteSetting.salesforce_leads_group_id = ""

      expect(described_class.create!(user)).to be_nil
      expect(user.reload.salesforce_lead_id).to be_nil
      expect(a_request(:get, query_path)).not_to have_been_made
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end

    it "skips creation when Leads are disabled despite a populated group" do
      SiteSetting.salesforce_leads_enabled = false
      Salesforce.seed_groups!
      Salesforce.leads_group.add(user)

      expect(described_class.create!(user)).to be_nil
      expect(user.reload.salesforce_lead_id).to be_nil
      expect(a_request(:get, query_path)).not_to have_been_made
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end

    it "reconciles a converted Lead instead of creating a replacement" do
      stub_salesforce_person_lookup("Lead", user.email)
      stub_salesforce_converted_lead_lookup(
        user.email,
        records: [{ Id: "converted-lead", IsConverted: true, ConvertedContactId: "contact1" }],
      )

      expect(described_class.create!(user)).to be_nil

      expect(user.reload.salesforce_contact_id).to eq("contact1")
      expect(user.salesforce_lead_id).to be_nil
      scope = { provider: "salesforce", account: instance_url, user_id: user.id }
      expect(Salesforce::RecordLink.find_by(**scope, object: "Lead").converted_to_id).to eq(
        "contact1",
      )
      expect(Salesforce::RecordLink.find_by(**scope, object: "Contact").external_id).to eq(
        "contact1",
      )
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end

    it "rolls back failed conversion reconciliation and completes it on retry" do
      Salesforce.seed_groups!
      stub_salesforce_person_lookup("Lead", user.email)
      stub_salesforce_converted_lead_lookup(
        user.email,
        records: [{ Id: "converted-lead", IsConverted: true, ConvertedContactId: "contact1" }],
      )
      scope = { provider: "salesforce", account: instance_url, user_id: user.id }
      lead_scope = scope.merge(object: "Lead")
      contact_scope = scope.merge(object: "Contact")
      Salesforce::RecordLink.link!(**lead_scope, external_id: "converted-lead")
      allow(user).to receive(:save_custom_fields).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs)
        raise ActiveRecord::StatementInvalid, "Simulated persistence failure"
      end

      expect { described_class.create!(user) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(Salesforce::RecordLink.find_by(**lead_scope)).not_to be_converted
      expect(Salesforce::RecordLink.find_by(**contact_scope)).to be_nil
      expect(user.reload.salesforce_contact_id).to be_nil
      allow(user).to receive(:save_custom_fields).and_call_original

      expect(described_class.create!(user)).to be_nil

      expect(Salesforce::RecordLink.find_by(**lead_scope).converted_to_id).to eq("contact1")
      expect(Salesforce::RecordLink.find_by(**contact_scope).external_id).to eq("contact1")
      expect(user.reload.salesforce_contact_id).to eq("contact1")
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end

    it "preserves an existing Contact association when a converted Lead points elsewhere" do
      user.upsert_custom_fields(Salesforce::Contact::ID_FIELD => "existing-contact")
      stub_salesforce_person_lookup("Lead", user.email)
      stub_salesforce_converted_lead_lookup(
        user.email,
        records: [{ Id: "converted-lead", IsConverted: true, ConvertedContactId: "other-contact" }],
      )

      expect(described_class.create!(user)).to be_nil
      expect(user.reload.salesforce_contact_id).to eq("existing-contact")
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end

    it "skips replacement creation when the converted Contact is inaccessible" do
      stub_salesforce_person_lookup("Lead", user.email)
      stub_salesforce_converted_lead_lookup(
        user.email,
        records: [{ Id: "converted-lead", IsConverted: true, ConvertedContactId: nil }],
      )

      expect(described_class.create!(user)).to be_nil
      expect(user.reload.salesforce_contact_id).to be_nil
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end

    it "creates a lead for another user when the source is blank and the group has a member" do
      SiteSetting.salesforce_lead_source = ""
      Salesforce.seed_groups!
      Salesforce.leads_group.add(Fabricate(:user))
      stub_salesforce_person_lookup("Lead", user.email)
      create_request =
        stub_request(:post, "#{api_path}/Lead").with(
          body: user.salesforce_lead_payload.to_json,
        ).to_return(status: 200, body: %({"id":"lead_123"}))

      expect(described_class.create!(user)).to eq("lead_123")
      expect(user.reload.salesforce_lead_id).to eq("lead_123")
      expect(create_request).to have_been_requested
      expect(Salesforce.leads_group.users.exists?(user.id)).to eq(true)
    end

    it "creates the first lead with a blank source when the Leads group is missing" do
      SiteSetting.salesforce_lead_source = ""
      SiteSetting.salesforce_leads_group_id = ""
      stub_salesforce_person_lookup("Lead", user.email)
      create_request =
        stub_request(:post, "#{api_path}/Lead").with(
          body: user.salesforce_lead_payload.to_json,
        ).to_return(status: 201, body: %({"id":"lead_123"}))

      expect(described_class.create!(user)).to eq("lead_123")
      expect(create_request).to have_been_requested
      expect(Salesforce.leads_group.users.exists?(user.id)).to eq(true)
    end

    it "sends the configured lead source" do
      Salesforce.seed_groups!
      Salesforce.leads_group.add(user)
      SiteSetting.salesforce_lead_source = "Community"
      stub_salesforce_person_lookup("Lead", user.email)
      create_lead =
        stub_request(:post, "#{api_path}/Lead").with(
          body: hash_including(LeadSource: "Community"),
        ).to_return(status: 200, body: %({"id":"123456"}))

      described_class.create!(user)

      expect(create_lead).to have_been_requested
    end

    it "omits the lead source when it is blank" do
      Salesforce.seed_groups!
      Salesforce.leads_group.add(user)
      SiteSetting.salesforce_lead_source = ""
      stub_salesforce_person_lookup("Lead", user.email)
      create_lead =
        stub_request(:post, "#{api_path}/Lead")
          .with { |request| JSON.parse(request.body).exclude?("LeadSource") }
          .to_return(status: 200, body: %({"id":"123456"}))

      described_class.create!(user)

      expect(create_lead).to have_been_requested
    end
  end
end
