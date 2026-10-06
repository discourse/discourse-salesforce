# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce do
  describe ".leads_enabled?" do
    fab!(:leads_group, :group)
    fab!(:user)

    before { SiteSetting.salesforce_leads_group_id = leads_group.id }

    it "preserves existing behavior with the default source and an empty group" do
      expect(SiteSetting.salesforce_lead_source).to eq("Web")
      expect(described_class.leads_enabled?).to eq(true)
    end

    it "enables Leads with a configured source and no group" do
      SiteSetting.salesforce_leads_group_id = ""
      SiteSetting.salesforce_lead_source = "Community"

      expect(described_class.leads_enabled?).to eq(true)
    end

    it "enables Leads with group members and a blank source" do
      SiteSetting.salesforce_lead_source = ""
      leads_group.add(user)

      expect(described_class.leads_enabled?).to eq(true)
    end

    it "disables Leads with a blank source and an empty or missing group" do
      SiteSetting.salesforce_lead_source = ""

      expect(described_class.leads_enabled?).to eq(false)

      SiteSetting.salesforce_leads_group_id = ""

      expect(described_class.leads_enabled?).to eq(false)
    end
  end
end
