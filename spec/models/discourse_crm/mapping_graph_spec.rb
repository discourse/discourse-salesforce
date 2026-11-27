# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::MappingGraph do
  fab!(:phone_field) { Fabricate(:user_field, name: "Phone", field_type: "text") }

  let(:phone) { "user_field_#{phone_field.id}" }

  def pull(
    *mappings,
    provider: "hubspot",
    object: "contact",
    name: "Pull contacts",
    policy: "overwrite"
  )
    DiscourseCrm::SyncConfiguration.new(
      provider: provider,
      direction: "inbound",
      account: "account",
      object: object,
      name: name,
      mappings:
        mappings.map do |source, destination|
          {
            "object" => object,
            "source" => source,
            "destination" => destination,
            "policy" => policy,
          }
        end,
    )
  end

  def push(*mappings, provider: "hubspot", object: "contact")
    DiscourseCrm::SyncConfiguration.new(
      provider: provider,
      direction: "outbound",
      account: "account",
      object: object,
      mappings:
        mappings.map do |source, destination|
          { "source" => source, "destination" => destination, "policy" => "overwrite" }
        end,
    )
  end

  def validate!(configuration, *others)
    described_class.new([configuration, *others]).validate!(configuration)
  end

  it "accepts pulls whose values never return to their source" do
    relay = push([phone, "Phone"], provider: "salesforce", object: "Contact")

    expect {
      validate!(pull(["mobilephone", phone], ["jobtitle", nil]), push(%w[first firstname]), relay)
    }.not_to raise_error
    # A keep mapping only fills blanks, so it settles a loop.
    expect {
      validate!(pull(["phone", phone], policy: "keep"), push([phone, "phone"]))
    }.not_to raise_error
  end

  it "treats a combined full name as its first and last name" do
    expect { validate!(pull(%w[firstname+lastname name]), push(%w[last lastname])) }.to raise_error(
      DiscourseCrm::InvalidMapping,
      /HubSpot contact.lastname → Discourse Name/,
    )
    salesforce = { provider: "salesforce", object: "Contact" }
    expect {
      validate!(pull(%w[Name name], **salesforce), push(%w[first FirstName], **salesforce))
    }.to raise_error(DiscourseCrm::InvalidMapping, /Salesforce Contact.FirstName → Discourse Name/)
  end

  it "rejects loops that pass through another CRM" do
    configurations = [
      push([phone, "Phone"], provider: "salesforce", object: "Contact"),
      pull(%w[Phone custom_field:sf_phone], provider: "salesforce", object: "Contact"),
      push(%w[custom_field:sf_phone phone]),
    ]

    expect { validate!(pull(["phone", phone]), *configurations) }.to raise_error(
      DiscourseCrm::InvalidMapping,
      /HubSpot contact.phone → Discourse Phone → Salesforce Contact.Phone → Discourse sf_phone → HubSpot contact.phone/,
    )
  end

  describe ".validate!" do
    before do
      SiteSetting.hubspot_enabled = true
      SiteSetting.enable_guided_sync_configuration = true
      SiteSetting.hubspot_portal_id = "12345"
    end

    def stored_pull(name, mappings)
      Fabricate(:hubspot_sync_configuration, name: name, mappings: mappings)
    end

    let(:phone_pull) do
      [
        {
          "object" => "contact",
          "source" => "phone",
          "destination" => phone,
          "policy" => "overwrite",
        },
      ]
    end

    it "rejects a Discourse field that another stored pull already overwrites" do
      stored_pull("Existing pull", phone_pull)

      expect {
        described_class.validate!(pull(["mobilephone", phone], name: "New pull"))
      }.to raise_error(
        DiscourseCrm::InvalidMapping,
        "Phone is already overwritten by the “Existing pull” sync. Two pulls can only share a Discourse field when at least one of them keeps the existing value.",
      )
      expect {
        described_class.validate!(pull(["mobilephone", phone], name: "New pull", policy: "keep"))
      }.not_to raise_error
    end

    it "checks the configuration being saved instead of its stored version" do
      existing = stored_pull("Existing pull", phone_pull)
      existing.mappings = [phone_pull.first.merge("source" => "mobilephone")]

      expect { described_class.validate!(existing) }.not_to raise_error
    end
  end
end
