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

    it "removes the stored data of a contact that no longer matches anyone" do
      import = described_class.new(configuration)
      import.import_page([hubspot_contact(501, "ada@example.com", lifecyclestage: "lead")])

      import.import_page([hubspot_contact(501, "gone@example.com", lifecyclestage: "lead")])

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
      Salesforce::RecordLink.link_many!([scope.merge(user_id: user.id, external_id: "502")])
      Salesforce::Record.store_many!([scope.merge(external_id: "502", data: {})])
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
              "properties" => %w[email lastmodifieddate lifecyclestage jobtitle],
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
