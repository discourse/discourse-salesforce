# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe ::Hubspot::ContactImport do
  include_context "with hubspot spec helper"

  let!(:configuration) { Fabricate(:hubspot_sync_configuration) }
  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }
  fab!(:other_user) { Fabricate(:verified_user, email: "grace@example.com") }
  fab!(:staged_user) { Fabricate(:user, staged: true, email: "staged@example.com") }

  let(:scope) { { provider: "hubspot", account: "12345", object: "contact" } }

  describe "#import_page" do
    it "links eligible users by any of their emails and stores only the selected properties" do
      UserEmail.create!(user: user, email: "ada.work@example.com")
      contacts = [
        hubspot_contact(
          501,
          "ADA@example.com",
          lifecyclestage: "customer",
          jobtitle: "CTO",
          city: "Paris",
        ),
        hubspot_contact(502, "ada.work@example.com", lifecyclestage: "lead"),
        hubspot_contact(503, "staged@example.com", lifecyclestage: "lead"),
        hubspot_contact(504, "nobody@example.com", lifecyclestage: "lead"),
        hubspot_contact(505, nil, lifecyclestage: "lead"),
      ]

      described_class.new(configuration).import_page(contacts)

      expect(configuration.record_links.pluck(:user_id, :external_id)).to contain_exactly(
        [user.id, "501"],
        [user.id, "502"],
      )
      expect(configuration.records.pluck(:external_id, :data)).to contain_exactly(
        ["501", { "lifecyclestage" => "customer", "jobtitle" => "CTO" }],
        ["502", { "lifecyclestage" => "lead" }],
      )
    end

    it "updates stored data and moves a contact whose email now belongs to another user" do
      import = described_class.new(configuration)
      import.import_page([hubspot_contact(501, "ada@example.com", lifecyclestage: "lead")])

      import.import_page(
        [
          hubspot_contact(501, "grace@example.com", lifecyclestage: "customer"),
          hubspot_contact(502, "ada@example.com", lifecyclestage: "lead"),
        ],
      )

      expect(configuration.record_links.pluck(:user_id, :external_id)).to contain_exactly(
        [other_user.id, "501"],
        [user.id, "502"],
      )
      expect(configuration.records.find_by(external_id: "501").data).to eq(
        "lifecyclestage" => "customer",
      )
    end

    it "removes the stored data of a contact that no longer matches anyone, and its company" do
      import = described_class.new(configuration)
      import.import_page(
        [
          hubspot_contact(
            501,
            "ada@example.com",
            lifecyclestage: "lead",
            associatedcompanyid: "900",
          ),
        ],
      )
      DiscourseCrm::Record.store_many!(
        [scope.merge(object: "company", external_id: "900", company_external_id: nil, data: {})],
      )

      import.import_page([hubspot_contact(501, "gone@example.com", lifecyclestage: "lead")])

      expect(configuration.record_links).to be_empty
      expect(DiscourseCrm::Record.where(provider: "hubspot")).to be_empty
    end

    it "unlinks a previously imported contact whose email was cleared" do
      import = described_class.new(configuration)
      import.import_page([hubspot_contact(501, user.email)])

      result = import.import_page([hubspot_contact(501, nil)])

      expect(result.reasons).to eq(user.id => "contact_unlinked")
      expect(configuration.record_links).to be_empty
      expect(configuration.records).to be_empty
    end

    it "keeps the link of a contact that shares its email with another contact on the page" do
      import = described_class.new(configuration)
      import.import_page([hubspot_contact(501, "ada@example.com")])

      import.import_page(
        [hubspot_contact(501, "ada@example.com"), hubspot_contact(502, "ada@example.com")],
      )

      expect(configuration.record_links.pluck(:user_id, :external_id)).to contain_exactly(
        [user.id, "501"],
        [user.id, "502"],
      )
    end

    it "leaves links for contacts outside the page untouched" do
      import = described_class.new(configuration)
      import.import_page([hubspot_contact(501, "ada@example.com")])

      import.import_page([hubspot_contact(502, "grace@example.com")])

      expect(configuration.record_links.pluck(:user_id, :external_id)).to contain_exactly(
        [user.id, "501"],
        [other_user.id, "502"],
      )
    end

    it "refuses to import for a configuration pinned to another portal" do
      configuration.update!(account: "99999")

      expect { described_class.new(configuration) }.to raise_error(
        Discourse::InvalidParameters,
        /hubspot_portal_id/,
      )
    end

    it "keeps the company id on contacts without requesting companies" do
      described_class.new(configuration).import_page(
        [hubspot_contact(501, "ada@example.com", associatedcompanyid: "900")],
      )

      expect(configuration.records.find_by(external_id: "501").company_external_id).to eq("900")
      expect(a_request(:post, hubspot_url("objects/companies/batch/read"))).not_to have_been_made
    end
  end

  describe "mapped Discourse fields" do
    fab!(:title_field) { Fabricate(:user_field, name: "Job title", field_type: "text") }
    fab!(:tier_field) do
      Fabricate(:user_field, name: "Tier", field_type: "dropdown").tap do |field|
        field.user_field_options.create!(value: "Gold")
      end
    end

    before do
      configuration.update!(
        mappings: [
          {
            "object" => "contact",
            "source" => "jobtitle",
            "destination" => "user_field_#{title_field.id}",
            "policy" => "overwrite",
          },
          {
            "object" => "contact",
            "source" => "tier",
            "destination" => "user_field_#{tier_field.id}",
            "policy" => "overwrite",
          },
          { "object" => "contact", "source" => "lifecyclestage" },
        ],
      )
    end

    it "fills Discourse fields from the user's most recently modified contact and stores its pulled properties" do
      UserEmail.create!(user: user, email: "ada.work@example.com")
      older = hubspot_contact(501, "ada@example.com", jobtitle: "Engineer", tier: "Gold")
      newer =
        hubspot_contact(502, "ada.work@example.com", jobtitle: "CTO", lifecyclestage: "customer")
      newer["properties"]["lastmodifieddate"] = "2026-11-02T10:00:00.000Z"

      page = described_class.new(configuration).import_page([newer, older])

      expect(user.reload.user_fields[title_field.id.to_s]).to eq("CTO")
      expect(user.user_fields[tier_field.id.to_s]).to be_nil
      expect(configuration.records.find_by(external_id: "502").data).to eq(
        "jobtitle" => "CTO",
        "lifecyclestage" => "customer",
      )
      expect(page.changed_user_ids).to eq([user.id])
      expect(page.destination_errors).to be_empty
    end

    it "fills Discourse fields from the newest contact whichever page it arrives on" do
      UserEmail.create!(user: user, email: "ada.work@example.com")
      older = hubspot_contact(501, "ada@example.com", jobtitle: "Engineer")
      newer = hubspot_contact(502, "ada.work@example.com", jobtitle: "CTO")
      newer["properties"]["lastmodifieddate"] = "2026-11-02T10:00:00.000Z"
      # Modified at the same moment as the older one; the higher id wins.
      tied = hubspot_contact(502, "ada.work@example.com", jobtitle: "CTO")

      [newer, tied].each do |winner|
        [[[winner], [older]], [[older], [winner]], [[older, winner]]].each do |pages|
          DiscourseCrm::Record.delete_all
          DiscourseCrm::RecordLink.delete_all
          user.user_custom_fields.delete_all
          import = described_class.new(configuration)

          pages.each { |page| import.import_page(page) }

          expect(user.reload.user_fields[title_field.id.to_s]).to eq("CTO")
        end
      end
    end

    it "ignores a response older than the stored version of the same contact" do
      newer = hubspot_contact(501, "ada@example.com", jobtitle: "CTO")
      newer["properties"]["lastmodifieddate"] = "2026-11-02T10:00:00.000Z"
      older = hubspot_contact(501, "ada@example.com", jobtitle: "Engineer")
      import = described_class.new(configuration)
      import.import_page([newer])

      import.import_page([older])

      expect(configuration.records.find_by(external_id: "501").data).to include("jobtitle" => "CTO")
      expect(user.reload.user_fields[title_field.id.to_s]).to eq("CTO")
    end

    it "keeps the newest stored contact's values and link when the user's own pull skips an outdated version" do
      UserEmail.create!(user: user, email: "ada.work@example.com")
      newest = hubspot_contact(501, "ada@example.com", jobtitle: "CTO")
      newest["properties"]["lastmodifieddate"] = "2026-11-03T10:00:00.000Z"
      described_class.new(configuration).import_page([newest])
      outdated = hubspot_contact(501, "ada@example.com", jobtitle: "Engineer")
      other = hubspot_contact(502, "ada.work@example.com", jobtitle: "Intern")
      other["properties"]["lastmodifieddate"] = "2026-11-02T10:00:00.000Z"
      stub_hubspot_batch_read([outdated, other])

      described_class.new(configuration).import_user(user)

      expect(user.reload.user_fields[title_field.id.to_s]).to eq("CTO")
      expect(configuration.record_links.pluck(:external_id)).to contain_exactly("501", "502")
    end

    it "joins the first and last name for the combined full name" do
      configuration.update!(
        mappings: [
          {
            "object" => "contact",
            "source" => Hubspot::InboundUsersFlow::FULL_NAME,
            "destination" => "name",
            "policy" => "overwrite",
          },
        ],
      )
      import = described_class.new(configuration)

      import.import_page(
        [hubspot_contact(501, "ada@example.com", firstname: "Augusta", lastname: "King")],
      )

      expect(import.requested_properties).to include("firstname", "lastname")
      expect(import.requested_properties).not_to include(Hubspot::InboundUsersFlow::FULL_NAME)
      expect(user.reload.name).to eq("Augusta King")
    end
  end

  describe "#import_user" do
    it "drops links and data for contacts whose email the user no longer has" do
      described_class.new(configuration).import_page(
        [
          hubspot_contact(501, "ada@example.com"),
          hubspot_contact(502, "old@example.com"),
          hubspot_contact(503, "grace@example.com"),
        ],
      )
      DiscourseCrm::RecordLink.link_many!(
        [scope.merge(direction: "inbound", user_id: user.id, external_id: "502")],
      )
      DiscourseCrm::Record.store_many!([scope.merge(external_id: "502", data: {})])
      stub_hubspot_batch_read([hubspot_contact(501, "ada@example.com")])

      described_class.new(configuration).import_user(user)

      expect(configuration.record_links.pluck(:user_id, :external_id)).to contain_exactly(
        [user.id, "501"],
        [other_user.id, "503"],
      )
      expect(configuration.records.pluck(:external_id)).to contain_exactly("501", "503")
    end

    it "reads the user's emails in one batch and links the matching contacts" do
      UserEmail.create!(user: user, email: "ada.work@example.com")
      stub_hubspot_batch_read(
        [
          hubspot_contact(501, "ada@example.com", lifecyclestage: "customer"),
          hubspot_contact(502, "ada.work@example.com", lifecyclestage: "lead"),
        ],
      )

      described_class.new(configuration).import_user(user)

      expect(
        a_request(:post, hubspot_url("objects/contacts/batch/read")).with(
          body:
            hash_including(
              "idProperty" => "email",
              "inputs" => [{ "id" => "ada@example.com" }, { "id" => "ada.work@example.com" }],
              "properties" => %w[
                email
                lastmodifieddate
                associatedcompanyid
                lifecyclestage
                jobtitle
              ],
            ),
        ),
      ).to have_been_made.once
      expect(configuration.record_links.pluck(:user_id, :external_id)).to contain_exactly(
        [user.id, "501"],
        [user.id, "502"],
      )
    end
  end
end
