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
    described_class.link!(**scope, external_id: "contact-1")
    expect(described_class.find_by(**scope).external_id).to eq("contact-1")
    [
      { provider: "hubspot" },
      { account: "another-account" },
      { object: "Lead" },
      { user_id: 43 },
    ].each do |difference|
      other_scope = scope.merge(difference)
      expect(described_class.find_by(**other_scope)).to be_nil
      described_class.link!(**other_scope, external_id: "other-record")
    end
    expect(described_class.find_by(**scope).external_id).to eq("contact-1")
    expect { described_class.create!(**scope, external_id: "duplicate") }.to raise_error(
      ActiveRecord::RecordNotUnique,
    )
  end

  it "preserves conversion metadata without rewriting an unchanged link" do
    described_class.link!(**scope, external_id: "contact-1", converted_from_id: "lead-1")

    queries = track_sql_queries { described_class.link!(**scope, external_id: "contact-1") }

    expect(queries.grep(/(?:INSERT INTO|UPDATE|DELETE FROM).*crm_record_links/i)).to be_empty
    expect(described_class.find_by(**scope).converted_from_id).to eq("lead-1")
    described_class.link!(**scope, external_id: "contact-2")
    link = described_class.find_by(**scope)
    expect(link.external_id).to eq("contact-2")
    expect(link.converted_from_id).to be_nil
  end

  it "removes only the requested record and preserves replacements and other accounts" do
    other_scope = scope.merge(account: "other-account")
    described_class.link!(**scope, external_id: "dead")
    described_class.link!(**other_scope, external_id: "dead")

    expect(described_class.unlink!(**scope, external_id: "dead")).to eq(true)
    expect(described_class.find_by(**scope)).to be_nil
    expect(described_class.find_by(**other_scope).external_id).to eq("dead")

    described_class.link!(**scope, external_id: "replacement")
    expect(described_class.unlink!(**scope, external_id: "dead")).to eq(false)
    expect(described_class.find_by(**scope).external_id).to eq("replacement")
  end

  it "retires converted Lead IDs and keeps the converted Contact link identifiable" do
    lead_scope = scope.merge(object: "Lead")
    described_class.link!(**lead_scope, external_id: "lead-1")
    described_class.link!(**scope, external_id: "contact-1", converted_from_id: "lead-1")

    described_class.mark_converted!(
      **lead_scope,
      external_id: "lead-1",
      to_object: "Contact",
      to_id: "contact-1",
    )
    described_class.link!(**scope, external_id: "contact-1")

    lead_link = described_class.find_by(**lead_scope)
    expect(lead_link).to be_converted
    expect(lead_link.slice(:external_id, :converted_to_object, :converted_to_id)).to eq(
      "external_id" => "lead-1",
      "converted_to_object" => "Contact",
      "converted_to_id" => "contact-1",
    )
    expect(described_class.within(**lead_scope.except(:user_id)).live).to be_empty
    contact_link = described_class.find_by(**scope)
    expect(contact_link).not_to be_converted
    expect(contact_link.slice(:external_id, :converted_from_id)).to eq(
      "external_id" => "contact-1",
      "converted_from_id" => "lead-1",
    )
    expect(described_class.unlink!(**lead_scope, external_id: "lead-1")).to eq(false)
  end
end
