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

  it "reads legacy Salesforce links without losing their original account and prefers new links" do
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      "configured_user_link:Contact:42",
      { id: "legacy", instance: "old-account" },
    )
    link = described_class.new(**scope)
    expect(link.read).to eq("id" => "legacy", "account" => "old-account")
    expect(described_class.new(**scope.merge(provider: "hubspot")).read).to be_nil
    link.write("current")
    expect(link.read).to eq("id" => "current", "account" => scope[:account])
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
