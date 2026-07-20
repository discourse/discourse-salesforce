# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::Contact do
  include_context "with salesforce spec helper"

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
  end
end
