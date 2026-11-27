# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Hubspot::CompanyImport do
  include_context "with hubspot spec helper"

  let!(:configuration) { Fabricate(:hubspot_company_pull) }

  def reference(contact_id, company_id)
    DiscourseCrm::Record.store_many!(
      [
        {
          provider: "hubspot",
          account: "12345",
          object: "contact",
          external_id: contact_id,
          company_external_id: company_id,
          data: {
          },
        },
      ],
    )
  end

  def company_data
    configuration.records.pluck(:external_id, :data).to_h
  end

  it "stores the selected properties and links a merged company under each requested ID" do
    reference("501", "900")
    reference("502", "902")
    stub_hubspot_company_batch_read(
      [
        hubspot_company(
          902,
          name: "Acme",
          plan_tier: "enterprise",
          domain: "acme.com",
          hs_merged_object_ids: "899;900",
        ),
      ],
      ids: %w[900 902],
    )

    result = described_class.new(configuration).refresh(%w[900 902])

    expect(
      a_request(:post, hubspot_url("objects/companies/batch/read")).with(
        body: hash_including("properties" => %w[name plan_tier hs_merged_object_ids]),
      ),
    ).to have_been_made.once
    expect(result.changed).to contain_exactly("900", "902")
    expect(company_data).to eq(
      "900" => {
        "name" => "Acme",
        "plan_tier" => "enterprise",
      },
      "902" => {
        "name" => "Acme",
        "plan_tier" => "enterprise",
      },
    )
    expect(DiscourseCrm::Record.find_by(external_id: "501").company.data).to include(
      "name" => "Acme",
    )
  end

  it "keeps returned companies, removes missing ones and reports each missing ID once" do
    DiscourseCrm::Record.store_many!(
      [
        {
          provider: "hubspot",
          account: "12345",
          object: "company",
          external_id: "901",
          company_external_id: nil,
          data: {
            "name" => "Old",
          },
        },
      ],
    )
    stub_hubspot_company_batch_read(
      [hubspot_company(902, name: "Acme", hs_merged_object_ids: "900")],
      ids: %w[900 901 902],
      errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: %w[900 901 901 902] } }],
    )

    expect(described_class.new(configuration).refresh(%w[900 901 902]).missing).to eq(%w[901])
    expect(company_data).to eq("900" => { "name" => "Acme" }, "902" => { "name" => "Acme" })
  end

  it "records responses it cannot match to the requested companies and stores nothing" do
    {
      [hubspot_company(901, name: "Private")] => "UNEXPECTED_COMPANY",
      [
        hubspot_company(901, hs_merged_object_ids: "900"),
        hubspot_company(902, hs_merged_object_ids: "900"),
      ] =>
        "CONFLICTING_COMPANY_IDS",
      [] => "INCOMPLETE_COMPANY_BATCH_READ",
    }.each do |results, code|
      stub_hubspot_company_batch_read(results, ids: %w[900])

      expect(described_class.new(configuration).refresh(%w[900])).to be_nil

      expect(DiscourseCrm::SyncAttempt.last).to have_attributes(outcome: "failed", user_id: nil)
      expect(DiscourseCrm::SyncAttempt.last.diagnostics).to include("codes" => [code])
    end
    expect(company_data).to be_empty
  end

  it "keeps stored companies when HubSpot rejects the batch" do
    import = described_class.new(configuration)
    stub_hubspot_company_batch_read([hubspot_company(900, name: "Acme")])
    import.refresh(%w[900])
    stub_hubspot_company_batch_read(
      [],
      errors: [{ category: "VALIDATION_ERROR", context: { ids: %w[900] } }],
    )

    import.refresh(%w[900])

    expect(DiscourseCrm::SyncAttempt.sole.outcome).to eq("failed")
    expect(company_data).to eq("900" => { "name" => "Acme" })
  end

  it "deletes stored companies with the company pull" do
    stub_hubspot_company_batch_read([hubspot_company(900, name: "Acme")])
    described_class.new(configuration).refresh(%w[900])

    configuration.destroy!

    expect(DiscourseCrm::Record.where(object: "company")).to be_empty
  end
end
