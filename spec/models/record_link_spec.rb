# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::RecordLink do
  let(:scope) do
    {
      provider: "salesforce",
      account: "https://example.salesforce.com",
      object: "Contact",
      user_id: 42,
    }
  end

  it "isolates links by provider, account, object and user" do
    link = described_class.new(**scope)
    link.write("contact-1")
    expect(link.read).to eq("id" => "contact-1", "account" => scope[:account])
    [
      { provider: "hubspot" },
      { account: "another-account" },
      { object: "Lead" },
      { user_id: 43 },
    ].each do |difference|
      other = described_class.new(**scope.merge(difference))
      expect(other.read).to be_nil
      other.write("other-record")
    end
    expect(link.read["id"]).to eq("contact-1")
  end

  it "preserves conversion metadata without rewriting an unchanged link" do
    link = described_class.new(**scope)
    link.write("contact-1", converted_from_lead_id: "lead-1")

    queries = track_sql_queries { link.write("contact-1") }

    expect(queries.grep(/(?:INSERT INTO|UPDATE|DELETE FROM).*plugin_store_rows/i)).to be_empty
    expect(link.read["converted_from_lead_id"]).to eq("lead-1")
    link.write("contact-2")
    expect(link.read).to eq("id" => "contact-2", "account" => scope[:account])
  end

  it "removes only the requested record and preserves replacements and other accounts" do
    link = described_class.new(**scope)
    other_link = described_class.new(**scope.merge(account: "other-account"))
    link.write("dead")
    other_link.write("dead")

    expect(link.remove("dead")).to eq(true)
    expect(link.read).to be_nil
    expect(other_link.read["id"]).to eq("dead")

    link.write("replacement")
    expect(link.remove("dead")).to eq(false)
    expect(link.read["id"]).to eq("replacement")
  end

  it "retires converted Lead IDs and keeps the converted Contact link identifiable" do
    lead_link = described_class.new(**scope.merge(object: "Lead"))
    contact_link = described_class.new(**scope)
    lead_link.write("lead-1")
    contact_link.write("contact-1", converted_from_lead_id: "lead-1")

    lead_link.mark_converted_to("contact-1")
    contact_link.write("contact-1")

    expect(lead_link.read).to eq(
      "account" => scope[:account],
      "converted_to" => {
        "object" => "Contact",
        "id" => "contact-1",
      },
    )
    expect(contact_link.read).to eq(
      "id" => "contact-1",
      "account" => scope[:account],
      "converted_from_lead_id" => "lead-1",
    )
  end
end
