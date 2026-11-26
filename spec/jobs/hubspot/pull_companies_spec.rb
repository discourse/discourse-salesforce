# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Jobs::Hubspot::PullCompanies do
  include_context "with hubspot spec helper"

  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }

  let!(:configuration) do
    Fabricate(
      :hubspot_company_pull,
      last_synced_at: Time.utc(2026, 11, 1, 12),
      mappings: [{ "id" => 1, "object" => "company", "source" => "name" }],
    )
  end

  before { described_class.clear }

  def enqueued_args
    described_class.jobs.map { |job| job["args"].first.except("current_site_id") }
  end

  def reference_companies(count)
    DiscourseCrm::Record.store_many!(
      (1..count).map do |index|
        {
          provider: "hubspot",
          account: "12345",
          object: "contact",
          external_id: "contact-#{index}",
          company_external_id: format("c%03d", index),
          data: {
          },
        }
      end,
    )
  end

  def link_contact(user, index)
    DiscourseCrm::RecordLink.create!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      direction: "inbound",
      user_id: user.id,
      external_id: "contact-#{index}",
    )
  end

  def company_data
    DiscourseCrm::Record
      .within(provider: "hubspot", account: "12345", object: "company")
      .pluck(:external_id, :data)
      .to_h
  end

  def company_batch_of(size)
    a_request(:post, hubspot_url("objects/companies/batch/read")).with do |request|
      JSON.parse(request.body).fetch("inputs").size == size
    end
  end

  def pull(**args)
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled", **args)
  end

  it "refreshes referenced companies one chunk at a time and then finishes" do
    freeze_time Time.utc(2026, 11, 2, 12)
    reference_companies(101)
    (1..101)
      .map { |index| format("c%03d", index) }
      .each_slice(100) do |ids|
        stub_hubspot_company_batch_read(ids.map { |id| hubspot_company(id, name: id) }, ids: ids)
      end

    pull
    expect(enqueued_args.last).to include("after" => "c100", "started_at" => "2026-11-02T12:00:00Z")
    described_class.new.execute(enqueued_args.last.symbolize_keys)
    expect(enqueued_args.last["after"]).to eq("c101")
    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 1, 12))
    described_class.new.execute(enqueued_args.last.symbolize_keys)

    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
    expect(company_batch_of(100)).to have_been_made.once
    expect(company_batch_of(1)).to have_been_made.once
    expect(company_data.size).to eq(101)
    expect(enqueued_args.size).to eq(2)
  end

  it "refreshes only the companies a user pull asks for, reports to that user and updates every linked user's segments" do
    SiteSetting.crm_segments_enabled = true
    contact_pull = Fabricate(:hubspot_sync_configuration)
    Jobs::DiscourseCrm::EvaluateSegments.clear
    configuration.update!(schedule: "manual")
    reference_companies(2)
    other_user = Fabricate(:user)
    [user, other_user].each { |member| link_contact(member, 2) }
    stub_hubspot_company_batch_read([hubspot_company("c002", name: "Acme")], ids: %w[c002])

    described_class.new.execute(
      configuration_id: configuration.id,
      reason: "contacts_pulled",
      company_ids: %w[c002],
      user_id: user.id,
    )

    expect(company_data).to eq("c002" => { "name" => "Acme" })
    expect(DiscourseCrm::SyncAttempt.pluck(:user_id)).to eq([user.id])
    expect(
      Jobs::DiscourseCrm::EvaluateSegments.jobs.map { |job| job["args"].first },
    ).to contain_exactly(
      a_hash_including(
        "configuration_id" => contact_pull.id,
        "user_ids" => match_array([user.id, other_user.id]),
      ),
    )
    expect(enqueued_args).to be_empty
    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 1, 12))
  end

  it "removes companies no stored contact points to when the pull finishes, even when some contacts have no company" do
    reference_companies(1)
    DiscourseCrm::Record.store_many!(
      [
        {
          provider: "hubspot",
          account: "12345",
          object: "company",
          external_id: "gone",
          company_external_id: nil,
          data: {
          },
        },
        # A NULL among the referenced ids must not stop the cleanup.
        {
          provider: "hubspot",
          account: "12345",
          object: "contact",
          external_id: "no-company",
          company_external_id: nil,
          data: {
          },
        },
      ],
    )
    stub_hubspot_company_batch_read([hubspot_company("c001", name: "Acme")], ids: %w[c001])

    pull
    described_class.new.execute(enqueued_args.last.symbolize_keys)

    expect(company_data).to eq("c001" => { "name" => "Acme" })
  end

  it "fetches company data before opening the write transaction" do
    reference_companies(1)
    baseline = DiscourseCrm::Record.connection.open_transactions
    request =
      stub_request(:post, hubspot_url("objects/companies/batch/read")).to_return do
        expect(DiscourseCrm::Record.connection.open_transactions).to eq(baseline)
        { body: { results: [hubspot_company("c001", name: "Acme")] }.to_json }
      end

    pull

    expect(request).to have_been_requested.once
  end

  it "reports a company change on every user whose contact points to it" do
    other = Fabricate(:verified_user)
    DiscourseCrm::Record.store_many!(
      [1, 2].map do |index|
        {
          provider: "hubspot",
          account: "12345",
          object: "contact",
          external_id: "contact-#{index}",
          company_external_id: "c001",
          data: {
          },
        }
      end,
    )
    link_contact(user, 1)
    link_contact(other, 2)
    stub_hubspot_company_batch_read([hubspot_company("c001", name: "Original")])
    pull
    stub_hubspot_company_batch_read([hubspot_company("c001", name: "Updated")])

    pull(started_at: 1.hour.from_now.iso8601)

    expect(company_data.fetch("c001")).to eq("name" => "Updated")
    expect(
      DiscourseCrm::SyncAttempt.where(reason: "imported_company").pluck(:user_id),
    ).to contain_exactly(user.id, other.id, user.id, other.id)
    expect(
      DiscourseCrm::SyncAttempt.where(configuration_id: configuration.id).pluck(:object).uniq,
    ).to eq(["company"])
  end

  it "summarizes unchanged company checks across pages and logs changes per user" do
    reference_companies(3)
    other_user = Fabricate(:user)
    [user, other_user, user].each.with_index(1) { |member, index| link_contact(member, index) }
    companies = (1..3).map { |i| hubspot_company(format("c%03d", i), name: "Acme") }
    stub_hubspot_company_batch_read(companies)
    Hubspot::CompanyImport.new(configuration).refresh(companies.pluck("id"))
    stub_hubspot_company_batch_read(
      [companies.first, hubspot_company("c002", name: "Updated")],
      ids: %w[c001 c002],
    )
    stub_hubspot_company_batch_read([companies.last], ids: %w[c003])

    stub_const(Hubspot::Api, :PAGE_SIZE, 2) do
      pull(started_at: Time.current.iso8601)
      described_class.new.execute(enqueued_args.last.symbolize_keys)
    end

    expect(DiscourseCrm::SyncAttempt.where(user_id: nil).sole).to have_attributes(
      reason: "unchanged_summary",
      diagnostics: {
        "count" => 2,
      },
    )
    expect(DiscourseCrm::SyncAttempt.where.not(user_id: nil).sole).to have_attributes(
      reason: "imported_company",
      user_id: other_user.id,
    )
  end

  it "counts the same missing companies whether they are fetched together or on separate pages" do
    reference_companies(2)
    ids = %w[c001 c002]
    ids.size.times { |index| link_contact(user, index + 1) }
    [ids, *ids.map { |id| [id] }].each do |batch|
      stub_hubspot_company_batch_read(
        [],
        ids: batch,
        errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: batch } }],
      )
    end

    [1, 2].each do |page_size|
      stub_const(Hubspot::Api, :PAGE_SIZE, page_size) do
        args = {
          configuration_id: configuration.id,
          reason: "scheduled",
          started_at: page_size.hours.ago.iso8601,
        }
        ids.each_slice(page_size) do
          described_class.new.execute(args)
          args = enqueued_args.last.symbolize_keys
        end
      end
    end

    expect(
      DiscourseCrm::SyncAttempt.where(reason: "missing_companies_summary").pluck(:diagnostics),
    ).to eq([{ "count" => 2 }, { "count" => 2 }])
  end

  it "continues when a merged company cannot be matched to its requested ID" do
    reference_companies(1)
    stub_hubspot_company_batch_read([hubspot_company("merged", name: "Acme")], ids: %w[c001])

    pull

    expect(company_data).to be_empty
    expect(DiscourseCrm::SyncAttempt.sole.diagnostics).to include("codes" => ["UNEXPECTED_COMPANY"])
    expect(enqueued_args.last).to include("after" => "c001", "history_result" => "recorded")
  end

  it "retries mixed company errors in either order without advancing the cursor" do
    reference_companies(1)
    errors = %w[VALIDATION_ERROR INTERNAL_ERROR].map { |category| { category: category } }
    [errors, errors.reverse].each do |ordered_errors|
      stub_hubspot_company_batch_read([], errors: ordered_errors)

      expect { pull }.to raise_error(Hubspot::InvalidApiResponse)

      expect(DiscourseCrm::SyncAttempt.last.diagnostics).to include(
        "category" => ["INTERNAL_ERROR"],
      )
      expect(enqueued_args).to be_empty
    end
  end

  it "retries only the rate limited chunk" do
    reference_companies(1)
    stub_request(:post, hubspot_url("objects/companies/batch/read")).to_return(
      status: 429,
      headers: {
        "Retry-After" => "9",
      },
    )
    freeze_time

    pull(started_at: Time.zone.now.iso8601, after: "")

    job = described_class.jobs.sole
    expect(job["at"] - Time.now.to_f).to be_within(1).of(9)
    expect(job["args"].first).to include("after" => "")
  end

  it "records a failing chunk on the configuration without moving the sync time" do
    reference_companies(1)
    stub_request(:post, hubspot_url("objects/companies/batch/read")).to_return(
      status: 500,
      body: "boom",
    )

    expect { pull }.to raise_error(Hubspot::InvalidApiResponse)

    expect(configuration.reload.slice(:last_synced_at, :last_error)).to eq(
      "last_synced_at" => Time.utc(2026, 11, 1, 12),
      "last_error" => "Hubspot::InvalidApiResponse",
    )
    expect(enqueued_args).to be_empty
  end
end
