# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce do
  describe ".leads_enabled?" do
    fab!(:leads_group, :group)
    fab!(:user)

    before { SiteSetting.salesforce_leads_group_id = leads_group.id }

    it "enables Leads by default even with a blank source and an empty group" do
      SiteSetting.salesforce_lead_source = ""

      expect(SiteSetting.salesforce_leads_enabled).to eq(true)
      expect(described_class.leads_enabled?).to eq(true)
    end

    it "disables Leads regardless of the source and group membership" do
      SiteSetting.salesforce_leads_enabled = false
      SiteSetting.salesforce_lead_source = "Community"
      leads_group.add(user)

      expect(described_class.leads_enabled?).to eq(false)
    end
  end
end
