# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::Lead do
  include_context "with salesforce spec helper"

  fab!(:user)

  describe ".create!" do
    it "skips creation when the Leads group is missing" do
      SiteSetting.salesforce_leads_group_id = ""

      expect(described_class.create!(user)).to be_nil
      expect(user.reload.salesforce_lead_id).to be_nil
      expect(a_request(:get, query_path)).not_to have_been_made
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end

    it "skips creation when the Leads group is empty" do
      Salesforce.seed_groups!

      expect(described_class.create!(user)).to be_nil
      expect(user.reload.salesforce_lead_id).to be_nil
      expect(a_request(:get, query_path)).not_to have_been_made
      expect(a_request(:post, "#{api_path}/Lead")).not_to have_been_made
    end

    it "creates a lead for another user when the Leads group has a member" do
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
  end
end
