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

    it "keeps the company id on contacts without requesting companies when none of their properties are selected" do
      described_class.new(configuration).import_page(
        [hubspot_contact(501, "ada@example.com", associatedcompanyid: "900")],
      )

      expect(configuration.records.find_by(external_id: "501").company_external_id).to eq("900")
      expect(a_request(:post, hubspot_url("objects/companies/batch/read"))).not_to have_been_made
    end
  end

  context "with company properties" do
    let!(:configuration) do
      Fabricate(
        :hubspot_sync_configuration,
        mappings: [
          { "id" => 1, "object" => "contact", "source" => "lifecyclestage" },
          { "id" => 2, "object" => "company", "source" => "name" },
          { "id" => 3, "object" => "company", "source" => "plan_tier" },
        ],
      )
    end
    let(:company_scope) { scope.merge(object: "company") }

    def company_data
      DiscourseCrm::Record.within(**company_scope).pluck(:external_id, :data).to_h
    end

    it "pulls the companies of matched contacts with the selected properties" do
      stub_hubspot_company_batch_read(
        [hubspot_company(900, name: "Acme", plan_tier: "enterprise", domain: "acme.com")],
        ids: %w[900],
      )

      described_class.new(configuration).import_page(
        [
          hubspot_contact(
            501,
            "ada@example.com",
            lifecyclestage: "customer",
            associatedcompanyid: "900",
          ),
          hubspot_contact(502, "grace@example.com", associatedcompanyid: "900"),
          hubspot_contact(503, "nobody@example.com", associatedcompanyid: "901"),
        ],
      )

      expect(
        a_request(:post, hubspot_url("objects/companies/batch/read")).with(
          body: hash_including("properties" => %w[name plan_tier hs_merged_object_ids]),
        ),
      ).to have_been_made.once
      expect(company_data).to eq("900" => { "name" => "Acme", "plan_tier" => "enterprise" })
      expect(configuration.records.pluck(:external_id, :company_external_id)).to contain_exactly(
        %w[501 900],
        %w[502 900],
      )
      expect(configuration.records.find_by(external_id: "501").company.data).to eq(
        "name" => "Acme",
        "plan_tier" => "enterprise",
      )
    end

    it "links a merged company to contacts referencing either ID" do
      stub_hubspot_company_batch_read(
        [hubspot_company(902, name: "Acme", hs_merged_object_ids: "899;900")],
        ids: %w[900 902],
      )
      described_class.new(configuration).import_page(
        [
          hubspot_contact(501, "ada@example.com", associatedcompanyid: "900"),
          hubspot_contact(502, "grace@example.com", associatedcompanyid: "902"),
        ],
      )
      expect(configuration.records.map { |contact| contact.company.data }).to eq(
        [{ "name" => "Acme" }, { "name" => "Acme" }],
      )
    end

    it "identifies an unexpected company without recording company data" do
      stub_hubspot_company_batch_read([hubspot_company(901, name: "Private")], ids: %w[900])
      expect { described_class.new(configuration).refresh_companies(%w[900]) }.to raise_error(
        Hubspot::InvalidApiResponse,
      ) { |error| expect(error.diagnostics).to eq(codes: ["UNEXPECTED_COMPANY"]) }
    end

    it "identifies two companies claiming the same merged ID" do
      stub_hubspot_company_batch_read(
        [
          hubspot_company(901, hs_merged_object_ids: "900"),
          hubspot_company(902, hs_merged_object_ids: "900"),
        ],
        ids: %w[900],
      )
      expect { described_class.new(configuration).refresh_companies(%w[900]) }.to raise_error(
        Hubspot::InvalidApiResponse,
      ) { |error| expect(error.diagnostics).to eq(codes: ["CONFLICTING_COMPANY_IDS"]) }
    end

    it "keeps returned companies and reports unresolved missing IDs once" do
      stub_hubspot_company_batch_read(
        [hubspot_company(902, name: "Acme", hs_merged_object_ids: "900")],
        ids: %w[900 901 902],
        errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: %w[900 901 901 902] } }],
      )

      expect(described_class.new(configuration).refresh_companies(%w[900 901 902]).missing).to eq(
        %w[901],
      )
      expect(company_data).to eq("900" => { "name" => "Acme" }, "902" => { "name" => "Acme" })
    end

    it "drops a company once no contact points at it and keeps one that is still referenced" do
      import = described_class.new(configuration)
      stub_hubspot_company_batch_read(
        [hubspot_company(900, name: "Acme"), hubspot_company(901, name: "Globex")],
        ids: %w[900 901],
      )
      import.import_page(
        [
          hubspot_contact(501, "ada@example.com", associatedcompanyid: "900"),
          hubspot_contact(502, "grace@example.com", associatedcompanyid: "901"),
        ],
      )
      stub_hubspot_company_batch_read([hubspot_company(901, name: "Globex")], ids: %w[901])

      import.import_page([hubspot_contact(501, "ada@example.com", associatedcompanyid: "901")])

      expect(company_data.keys).to eq(%w[901])
      expect(configuration.records.pluck(:external_id, :company_external_id)).to contain_exactly(
        %w[501 901],
        %w[502 901],
      )
    end

    it "imports contact changes and records a separate failure when HubSpot omits a requested company" do
      import = described_class.new(configuration)
      stub_hubspot_company_batch_read([hubspot_company(900, name: "Acme")], ids: %w[900])
      import.import_page(
        [
          hubspot_contact(
            501,
            "ada@example.com",
            associatedcompanyid: "900",
            lifecyclestage: "lead",
          ),
        ],
      )
      contacts = [
        hubspot_contact(
          501,
          "ada@example.com",
          associatedcompanyid: "901",
          lifecyclestage: "customer",
        ),
      ]
      stub_hubspot_company_batch_read([], ids: %w[901])
      import.import_page(contacts)
      expect(DiscourseCrm::SyncAttempt.sole.diagnostics).to include(
        "codes" => ["INCOMPLETE_COMPANY_BATCH_READ"],
      )
      expect(company_data).to be_empty
      expect(configuration.records.find_by!(external_id: "501").data).to eq(
        "lifecyclestage" => "customer",
      )
      stub_hubspot_company_batch_read([hubspot_company(901, name: "Globex")], ids: %w[901])
      stub_hubspot_contact_list(contacts)
      Jobs::Hubspot::SyncConfiguration.new.execute(
        configuration_id: configuration.id,
        reason: "backfill",
      )
      history =
        DiscourseCrm::SyncAttempt.find_by!(configuration_id: configuration.id, user_id: user.id)
      expect(history).to have_attributes(reason: "imported", diagnostics: {})
      expect(configuration.records.find_by!(external_id: "501").data).to include(
        "lifecyclestage" => "customer",
      )
      expect(company_data).to eq("901" => { "name" => "Globex" })
    end

    it "removes a company HubSpot reports as missing and leaves its contacts without a company" do
      import = described_class.new(configuration)
      stub_hubspot_company_batch_read([hubspot_company(900, name: "Acme")])
      import.import_page([hubspot_contact(501, "ada@example.com", associatedcompanyid: "900")])
      stub_hubspot_company_batch_read(
        [],
        errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: %w[900] } }],
      )

      import.import_page([hubspot_contact(501, "ada@example.com", associatedcompanyid: "900")])

      expect(company_data).to eq({})
      expect(configuration.records.find_by(external_id: "501").company).to be_nil
    end

    it "keeps stored companies when the company batch fails for another reason" do
      import = described_class.new(configuration)
      stub_hubspot_company_batch_read([hubspot_company(900, name: "Acme")])
      import.import_page([hubspot_contact(501, "ada@example.com", associatedcompanyid: "900")])
      stub_hubspot_company_batch_read(
        [],
        errors: [{ category: "VALIDATION_ERROR", context: { ids: %w[900] } }],
      )

      import.import_page([hubspot_contact(501, "ada@example.com", associatedcompanyid: "900")])
      expect(DiscourseCrm::SyncAttempt.sole.outcome).to eq("failed")

      expect(company_data).to eq("900" => { "name" => "Acme" })
    end

    it "removes the orphaned company of a contact the user no longer has" do
      import = described_class.new(configuration)
      old_email = UserEmail.create!(user: user, email: "old@example.com")
      stub_hubspot_company_batch_read(
        [hubspot_company(900, name: "Acme"), hubspot_company(901, name: "Globex")],
        ids: %w[900 901],
      )
      import.import_page(
        [
          hubspot_contact(501, "ada@example.com", associatedcompanyid: "900"),
          hubspot_contact(502, "old@example.com", associatedcompanyid: "901"),
        ],
      )
      old_email.destroy!
      stub_hubspot_batch_read([hubspot_contact(501, "ada@example.com", associatedcompanyid: "900")])
      stub_hubspot_company_batch_read([hubspot_company(900, name: "Acme")], ids: %w[900])

      import.import_user(user.reload)

      expect(configuration.records.pluck(:external_id)).to eq(%w[501])
      expect(company_data.keys).to eq(%w[900])
    end

    it "drops stored companies once no company property is selected any more" do
      stub_hubspot_company_batch_read([hubspot_company(900, name: "Acme")])
      described_class.new(configuration).import_page(
        [hubspot_contact(501, "ada@example.com", associatedcompanyid: "900")],
      )
      configuration.update!(
        mappings: [{ "id" => 1, "object" => "contact", "source" => "lifecyclestage" }],
      )

      described_class.new(configuration).import_page(
        [hubspot_contact(502, "grace@example.com", associatedcompanyid: "900")],
      )

      expect(company_data).to eq({})
      expect(configuration.records.pluck(:company_external_id).uniq).to eq(%w[900])
      expect(a_request(:post, hubspot_url("objects/companies/batch/read"))).to have_been_made.once
    end

    it "refreshes the companies contacts reference and drops the ones reported gone" do
      import = described_class.new(configuration)
      stub_hubspot_company_batch_read(
        [hubspot_company(900, plan_tier: "pro"), hubspot_company(901, plan_tier: "pro")],
      )
      import.import_page(
        [
          hubspot_contact(501, "ada@example.com", associatedcompanyid: "900"),
          hubspot_contact(502, "grace@example.com", associatedcompanyid: "901"),
        ],
      )
      stub_hubspot_company_batch_read(
        [hubspot_company(900, plan_tier: "enterprise")],
        ids: %w[900 901],
      )
      expect { import.refresh_companies(%w[900 901]) }.to raise_error(
        Hubspot::InvalidApiResponse,
        "Incomplete company batch read response",
      )
      expect(company_data).to eq(
        "900" => {
          "plan_tier" => "pro",
        },
        "901" => {
          "plan_tier" => "pro",
        },
      )
      stub_hubspot_company_batch_read(
        [hubspot_company(900, plan_tier: "enterprise")],
        ids: %w[900 901],
        errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: %w[901] } }],
      )

      expect(import.referenced_company_ids(after: "")).to eq(%w[900 901])
      expect(import.referenced_company_ids(after: "900")).to eq(%w[901])
      import.refresh_companies(%w[900 901])

      expect(company_data).to eq("900" => { "plan_tier" => "enterprise" })
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
