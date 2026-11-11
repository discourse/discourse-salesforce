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

  context "with pulled hubspot records" do
    include_context "with hubspot spec helper"

    it "exposes them through users and configurations" do
      user = Fabricate(:user)
      configuration = Fabricate(:hubspot_sync_configuration)
      link_scope = { provider: "hubspot", account: "12345", object: "contact", user_id: user.id }
      described_class.link_many!(
        [link_scope.merge(external_id: "501"), link_scope.merge(external_id: "502")],
      )
      described_class.link!(**scope, external_id: "contact-1", user_id: user.id)
      pulled = Fabricate(:crm_record, external_id: "501", data: { "jobtitle" => "Engineer" })

      expect(user.crm_records.hubspot).to eq([pulled])
      expect(user.crm_record_links.map(&:external_id)).to contain_exactly("501", "502", "contact-1")
      expect(configuration.record_links.map(&:external_id)).to contain_exactly("501", "502")
      expect(described_class.find_by(external_id: "502").record).to be_nil
      expect(pulled.record_links.map(&:user_id)).to eq([user.id])
    end
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

  it "allows several hubspot contacts per user while keeping salesforce to one record per user" do
    hubspot_scope = { provider: "hubspot", account: "12345", object: "contact", user_id: 42 }

    described_class.link_many!(
      [
        hubspot_scope.merge(external_id: "501"),
        hubspot_scope.merge(external_id: "877"),
        hubspot_scope.merge(external_id: "501"),
      ],
    )
    described_class.link_many!([hubspot_scope.merge(external_id: "877")])

    expect(described_class.where(**hubspot_scope).pluck(:external_id)).to contain_exactly(
      "501",
      "877",
    )
    described_class.link!(**scope, external_id: "contact-1")
    expect { described_class.create!(**scope, external_id: "contact-2") }.to raise_error(
      ActiveRecord::RecordNotUnique,
    )
    described_class.link!(**scope, external_id: "contact-2")
    expect(described_class.where(**scope).pluck(:external_id)).to eq(["contact-2"])
  end
end
