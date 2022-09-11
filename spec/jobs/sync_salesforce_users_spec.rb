# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe Jobs::SyncSalesforceUsers do
  include_context "salesforce spec helper"

  fab!(:user1) { Fabricate(:user) }
  fab!(:user2) { Fabricate(:user) }

  before do
    user1.salesforce_lead_id = "lead_123"
    user1.save!

    user2.salesforce_contact_id = "contact_123"
    user2.save!

    path = api_path.sub("sobjects", "composite/sobjects")
    stub_request(:get, "#{path}/Lead?fields=ConvertedContactId&ids=lead_123").
      to_return(status: 200, body: [{ ConvertedContactId: "contact_456", Id: "lead_123" }].to_json)
    stub_request(:get, "#{path}/Contact?fields=MasterRecordId&ids=contact_456,contact_123").
      to_return(status: 200, body: [{ MasterRecordId: "contact_789", Id: "contact_123" }].to_json)
  end

  it 'syncs lead to contact conversions and contact merges from Salesforce' do
    described_class.new.execute({})

    fields = user1.reload.custom_fields
    expect(fields[::Salesforce::Lead::ID_FIELD]).to eq(nil)
    expect(fields[::Salesforce::Contact::ID_FIELD]).to eq("contact_456")

    expect(user2.reload.salesforce_contact_id).to eq("contact_789")
  end
end
