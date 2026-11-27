# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Jobs::Hubspot::SyncConfiguration do
  include_context "with hubspot spec helper"

  let!(:configuration) { Fabricate(:hubspot_sync_configuration) }

  fab!(:user) { Fabricate(:verified_user, email: "ada@example.com") }

  def enqueued_args
    Jobs::Hubspot::SyncConfiguration.jobs.map { |job| job["args"].first.except("current_site_id") }
  end

  before do
    Jobs::Hubspot::SyncConfiguration.clear
    Jobs::DiscourseCrm::EvaluateSegments.clear
    SiteSetting.crm_segments_enabled = true
  end

  it "keeps a paged contact unlink and its history atomic across retries" do
    args = { configuration_id: configuration.id, reason: "backfill" }
    stub_hubspot_contact_list([hubspot_contact(501, user.email)])
    described_class.new.execute(args)
    stub_hubspot_contact_list([hubspot_contact(501, "other@example.org")])
    DiscourseCrm::SyncConfiguration
      .any_instance
      .stubs(:record_import_results)
      .raises(ActiveRecord::Deadlocked)
    expect { described_class.new.execute(args) }.to raise_error(ActiveRecord::Deadlocked)
    expect(configuration.record_links.pluck(:external_id)).to eq(["501"])
    DiscourseCrm::SyncConfiguration.any_instance.unstub(:record_import_results)
    described_class.new.execute(args)
    expect(configuration.record_links).to be_empty
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported contact_unlinked],
    )
  end

  it "clears recovered users' quota errors without clearing failures outside the imported page" do
    other_user = Fabricate(:verified_user)
    outbound =
      Fabricate(:sync_configuration, provider: "hubspot", account: "12345", object: "contact")
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      status: 429,
      body: { policyName: "DAILY" }.to_json,
    )
    Jobs::Hubspot::SyncUser.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::DailyQuotaExceeded")
    [[configuration, other_user], [outbound, user]].each do |record, member|
      DiscourseCrm::SyncConfiguration.record_result(
        record.id,
        member.id,
        error: Hubspot::DailyQuotaExceeded.new,
      )
    end
    stub_hubspot_contact_list([hubspot_contact(501, user.email, jobtitle: "Engineer")])

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(configuration.record_link_for(user.id).external_id).to eq("501")
    expect(configuration.reload.last_synced_at).to be_present
    expect(configuration.sync_states.find_by(user_id: user.id).slice(:error, :error_at)).to eq(
      "error" => nil,
      "error_at" => nil,
    )
    expect(configuration.sync_states.find_by(user_id: other_user.id).error).to eq(
      "Hubspot::DailyQuotaExceeded",
    )
    expect(outbound.sync_states.find_by(user_id: user.id).error).to eq(
      "Hubspot::DailyQuotaExceeded",
    )
    expect(configuration.sync_status["error"]).to eq("Hubspot::DailyQuotaExceeded")
    stub_hubspot_contact_search([hubspot_contact(502, other_user.email)])
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    expect(configuration.reload.sync_status).not_to have_key("error")
  end

  it "records an unlink for the previous owner when a contact changes email" do
    other_user = Fabricate(:verified_user)
    args = { configuration_id: configuration.id, reason: "backfill" }
    stub_hubspot_contact_list([hubspot_contact(501, user.email)])
    described_class.new.execute(args)
    stub_hubspot_contact_list([hubspot_contact(501, other_user.email)])
    described_class.new.execute(args)
    expect(configuration.record_links.pluck(:user_id)).to eq([other_user.id])
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported contact_unlinked],
    )
    expect(DiscourseCrm::SyncAttempt.where(user_id: other_user.id).sole.reason).to eq("imported")
  end

  it "records only an unlink for a user whose other contact is unchanged on the scheduled page" do
    next_owner = Fabricate(:verified_user)
    retained = hubspot_contact(501, user.email)
    stub_hubspot_contact_list([retained, hubspot_contact(502, user.email)])
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    stub_hubspot_contact_search([retained, hubspot_contact(502, next_owner.email)])
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported contact_unlinked],
    )
    expect(DiscourseCrm::SyncAttempt.where(user_id: next_owner.id).sole.reason).to eq("imported")
  end

  it "records the first unchanged scheduled pull after a user's rate limit in their history" do
    contact = hubspot_contact(501, user.email)
    stub_hubspot_contact_list([contact])
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      status: 429,
      headers: {
        "Retry-After" => "17",
      },
    )
    Jobs::Hubspot::SyncUser.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "change",
    )

    Discourse.redis.without_namespace.expire("hubspot_api:12345:6789:cooldown", 0)
    stub_hubspot_contact_search([contact])
    2.times { described_class.new.execute(configuration_id: configuration.id, reason: "scheduled") }
    expect(
      DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:outcome, :reason),
    ).to eq([%w[success imported], %w[failed failed], %w[success unchanged]])
    expect(DiscourseCrm::SyncAttempt.where(reason: "unchanged_summary").sole.diagnostics).to eq(
      "count" => 1,
    )
  end

  it "records daily quota exhaustion without scheduling another import" do
    stub_request(:get, %r{api.hubapi.com/crm/v3/objects/contacts}).to_return(
      status: 429,
      body: { policyName: "DAILY" }.to_json,
    )
    described_class.clear
    expect {
      described_class.new.execute(
        configuration_id: configuration.id,
        user_id: user.id,
        reason: "backfill",
      )
    }.not_to raise_error
    expect(described_class.jobs).to be_empty
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::DailyQuotaExceeded")
  end

  it "summarizes an unchanged contact from an overlapping search and reports later mapped changes" do
    configuration.update!(last_synced_at: 1.hour.ago)
    args = { configuration_id: configuration.id, reason: "scheduled" }
    stub_hubspot_contact_search([hubspot_contact(501, user.email, jobtitle: "Engineer")])
    2.times { described_class.new.execute(args) }
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).pluck(:reason)).to eq(["imported"])
    expect(DiscourseCrm::SyncAttempt.where(user_id: nil).sole).to have_attributes(
      reason: "unchanged_summary",
      diagnostics: {
        "count" => 1,
      },
    )

    stub_hubspot_contact_search([hubspot_contact(501, user.email, jobtitle: "Designer")])
    described_class.new.execute(args)
    expect(DiscourseCrm::SyncAttempt.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
      %w[imported imported],
    )
  end

  it "refreshes the stored property labels on the first page of a run only" do
    stub_request(:get, hubspot_url("properties/contacts")).to_return(
      body: {
        results: [
          {
            name: "lifecyclestage",
            label: "Lifecycle stage",
            type: "enumeration",
            options: [{ value: "lead", label: "Lead" }],
          },
          { name: "jobtitle", label: "Job title", type: "string" },
        ],
      }.to_json,
    )
    stub_hubspot_contact_list([hubspot_contact(501, "ada@example.com")], after: "100")

    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    expect(configuration.reload.property_metadata).to eq(
      "contact" => {
        "lifecyclestage" => {
          "label" => "Lifecycle stage",
          "options" => {
            "lead" => "Lead",
          },
        },
        "jobtitle" => {
          "label" => "Job title",
          "options" => {
          },
        },
      },
    )

    configuration.update_columns(property_metadata: {})
    stub_hubspot_contact_list([], query: { after: "100" })
    described_class.new.execute(enqueued_args.first.symbolize_keys)

    expect(configuration.reload.property_metadata).to eq({})
    expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.once

    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.twice
  end

  it "lists every contact on backfill, follows the cursor and records the run start as the sync time" do
    freeze_time Time.utc(2026, 11, 2, 12)
    started_at = Time.zone.now
    stub_hubspot_contact_list([hubspot_contact(501, "ada@example.com")], after: "100")

    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    expect(
      a_request(:get, hubspot_url("objects/contacts")).with(
        query: {
          limit: 100,
          properties: "email,lastmodifieddate,associatedcompanyid,lifecyclestage,jobtitle",
        },
      ),
    ).to have_been_made.once
    expect(DiscourseCrm::RecordLink.where(user_id: user.id).pluck(:external_id)).to eq(["501"])
    expect(configuration.reload.last_synced_at).to be_nil
    expect(Jobs::DiscourseCrm::EvaluateSegments.jobs).to be_empty
    expect(enqueued_args).to eq(
      [
        {
          "configuration_id" => configuration.id,
          "reason" => "backfill",
          "started_at" => started_at.iso8601,
          "history_result" => "recorded",
          "after" => "100",
        },
      ],
    )

    stub_hubspot_contact_list([], query: { after: "100" })
    freeze_time 10.minutes.from_now
    described_class.new.execute(enqueued_args.first.symbolize_keys)

    expect(DiscourseCrm::SyncAttempt.where(user_id: nil)).to be_empty
    expect(configuration.reload.last_synced_at).to eq_time(started_at)
    expect(
      Jobs::DiscourseCrm::EvaluateSegments.jobs.map { |job| job["args"].first },
    ).to contain_exactly(hash_including("configuration_id" => configuration.id))
  end

  it "searches contacts modified since the previous run with an overlap and never moves the sync time backwards" do
    configuration.update!(last_synced_at: Time.utc(2026, 11, 1, 12), last_error: "Boom")
    freeze_time Time.utc(2026, 11, 2, 12)
    stub_hubspot_contact_search([hubspot_contact(501, "ada@example.com")])

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(
      a_request(:post, hubspot_url("objects/contacts/search")).with(
        body:
          hash_including(
            "filterGroups" => [
              {
                "filters" => [
                  {
                    "propertyName" => "lastmodifieddate",
                    "operator" => "GTE",
                    "value" => Time.utc(2026, 11, 1, 11, 55).to_i.*(1000).to_s,
                  },
                ],
              },
            ],
            "sorts" => [{ "propertyName" => "lastmodifieddate", "direction" => "ASCENDING" }],
          ),
      ),
    ).to have_been_made.once
    expect(configuration.reload.slice(:last_synced_at, :last_error, :last_error_at)).to eq(
      "last_synced_at" => Time.utc(2026, 11, 2, 12),
      "last_error" => nil,
      "last_error_at" => nil,
    )

    described_class.new.execute(
      configuration_id: configuration.id,
      reason: "scheduled",
      started_at: Time.utc(2026, 11, 2, 11).iso8601,
    )

    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
  end

  it "lists every contact on a scheduled run that has never synced" do
    stub_hubspot_contact_list([])

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(
      a_request(:get, hubspot_url("objects/contacts")).with(query: hash_including({})),
    ).to have_been_made.once
    expect(a_request(:post, hubspot_url("objects/contacts/search"))).not_to have_been_made
  end

  it "restarts the search from the last modified date when the cursor reaches HubSpot's limit" do
    freeze_time Time.utc(2026, 11, 2, 12)
    configuration.update!(last_synced_at: 1.day.ago)
    stub_hubspot_contact_search(
      [hubspot_contact(501, "ada@example.com", lastmodifieddate: "2026-11-02T09:30:00.000Z")],
      after: "10000",
    )

    described_class.new.execute(
      configuration_id: configuration.id,
      reason: "scheduled",
      after: "9900",
      since: 1.day.ago.iso8601,
      started_at: Time.zone.now.iso8601,
    )

    expect(enqueued_args).to contain_exactly(
      {
        "configuration_id" => configuration.id,
        "reason" => "scheduled",
        "started_at" => Time.zone.now.iso8601,
        "since" => Time.utc(2026, 11, 2, 9, 30).iso8601,
        "history_result" => "recorded",
      },
    )
  end

  it "stops with an error when the search limit is reached without a later modified date" do
    freeze_time Time.utc(2026, 11, 2, 12)
    since = Time.utc(2026, 11, 2, 9, 30)
    stub_hubspot_contact_search(
      [hubspot_contact(501, "ada@example.com", lastmodifieddate: since.iso8601(3))],
      after: "10000",
    )

    expect {
      described_class.new.execute(
        configuration_id: configuration.id,
        reason: "scheduled",
        after: "9900",
        since: since.iso8601,
        started_at: Time.zone.now.iso8601,
      )
    }.to raise_error(Hubspot::InvalidApiResponse, /without a later modified date/)
    expect(
      DiscourseCrm::SyncAttempt.where(outcome: "failed").sole.diagnostics.fetch("codes"),
    ).to eq(["CONTACT_SEARCH_LIMIT"])

    expect(enqueued_args).to be_empty
    expect(configuration.reload.last_error).to eq("Hubspot::InvalidApiResponse")
  end

  it "keeps searching with the same window across pages of a scheduled run" do
    configuration.update!(last_synced_at: Time.utc(2026, 11, 1, 12))
    freeze_time Time.utc(2026, 11, 2, 12)
    stub_hubspot_contact_search([hubspot_contact(501, "ada@example.com")], after: "100")

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    described_class.new.execute(enqueued_args.first.symbolize_keys)

    expect(enqueued_args.first).to include(
      "after" => "100",
      "since" => Time.utc(2026, 11, 1, 11, 55).iso8601,
    )
    expect(
      a_request(:post, hubspot_url("objects/contacts/search")).with(
        body:
          hash_including(
            "after" => "100",
            "filterGroups" => [
              {
                "filters" => [
                  {
                    "propertyName" => "lastmodifieddate",
                    "operator" => "GTE",
                    "value" => Time.utc(2026, 11, 1, 11, 55).to_i.*(1000).to_s,
                  },
                ],
              },
            ],
          ),
      ),
    ).to have_been_made.once
    expect(
      a_request(:get, hubspot_url("objects/contacts")).with(query: hash_including({})),
    ).not_to have_been_made
  end

  it "waits for the rate limit window before retrying the same page" do
    configuration.update!(last_synced_at: 1.day.ago)
    stub_hubspot_contact_search([], status: 429, headers: { "Retry-After" => "17" })
    freeze_time

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(Jobs::Hubspot::SyncConfiguration.jobs.map { |job| job["at"] - Time.now.to_f }).to all(
      be_within(1).of(17),
    )
    expect(configuration.reload.last_error).to be_nil
  end

  it "records failures on the configuration and raises so the job retries" do
    stub_request(:get, hubspot_url("objects/contacts")).with(query: hash_including({})).to_return(
      status: 500,
      body: "boom",
    )

    expect {
      described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    }.to raise_error(Hubspot::InvalidApiResponse)

    expect(configuration.reload.last_error).to eq("Hubspot::InvalidApiResponse")
  end

  context "with company properties" do
    let!(:configuration) do
      Fabricate(
        :hubspot_sync_configuration,
        last_synced_at: Time.utc(2026, 11, 1, 12),
        mappings: [{ "id" => 1, "object" => "company", "source" => "name" }],
      )
    end

    before { stub_hubspot_properties(%w[name], object: "company") }

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

    it "fetches company data before opening the write transaction for a backfill or scheduled refresh" do
      stub_hubspot_contact_list([hubspot_contact(501, user.email, associatedcompanyid: "c001")])
      baseline = DiscourseCrm::Record.connection.open_transactions
      request =
        stub_request(:post, hubspot_url("objects/companies/batch/read")).to_return do
          expect(DiscourseCrm::Record.connection.open_transactions).to eq(baseline)
          { body: { results: [hubspot_company("c001", name: "Acme")] }.to_json }
        end

      described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
      described_class.new.execute(
        configuration_id: configuration.id,
        reason: "scheduled",
        companies_after: "",
      )
      expect(request).to have_been_requested.twice
    end

    it "attributes a shared company change to both users when only one contact was modified" do
      other = Fabricate(:verified_user)
      contacts =
        [user, other].map do |member|
          hubspot_contact(member.id, member.email, associatedcompanyid: "c001")
        end
      stub_hubspot_company_batch_read([hubspot_company("c001", name: "Original")])
      Hubspot::ContactImport.new(configuration).import_page(contacts)
      stub_hubspot_contact_search([contacts.first])
      stub_hubspot_company_batch_read([hubspot_company("c001", name: "Updated")])
      described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
      expect(company_data.fetch("c001")).to eq("name" => "Original")
      described_class.new.execute(enqueued_args.last.symbolize_keys)
      expect(company_data.fetch("c001")).to eq("name" => "Updated")
      expect(
        DiscourseCrm::SyncAttempt.where(reason: "imported_company").pluck(:user_id),
      ).to contain_exactly(user.id, other.id)
      expect(DiscourseCrm::SyncAttempt.where(reason: "unchanged_summary").sole.diagnostics).to eq(
        "count" => 1,
      )
    end

    it "pulls the companies of unchanged contacts once company properties are added" do
      freeze_time Time.utc(2026, 11, 2, 12)
      reference_companies(1)
      DiscourseCrm::RecordLink.create!(
        provider: "hubspot",
        account: "12345",
        object: "contact",
        direction: "inbound",
        user_id: user.id,
        external_id: "contact-1",
      )
      stub_hubspot_contact_search([])
      stub_hubspot_company_batch_read([hubspot_company("c001", name: "Acme")], ids: %w[c001])

      described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
      described_class.new.execute(enqueued_args.last.symbolize_keys)

      expect(company_data).to eq("c001" => { "name" => "Acme" })
      expect(DiscourseCrm::SyncAttempt.last).to have_attributes(
        user_id: user.id,
        reason: "imported_company",
        diagnostics: {
        },
      )
      described_class.new.execute(enqueued_args.last.symbolize_keys)
      expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
    end

    it "continues a scheduled refresh when a merged company cannot be matched to its requested ID" do
      reference_companies(1)
      stub_hubspot_company_batch_read([hubspot_company("merged", name: "Acme")], ids: %w[c001])
      described_class.new.execute(
        configuration_id: configuration.id,
        reason: "scheduled",
        companies_after: "",
      )
      expect(company_data).to be_empty
      expect(DiscourseCrm::SyncAttempt.sole.diagnostics).to include(
        "codes" => ["UNEXPECTED_COMPANY"],
      )
      expect(enqueued_args.last).to include(
        "companies_after" => "c001",
        "history_result" => "recorded",
      )
      described_class.new.execute(enqueued_args.last.symbolize_keys)
      expect(DiscourseCrm::SyncAttempt.sole.outcome).to eq("failed")
    end

    it "retries mixed company errors in either order without advancing the cursor" do
      reference_companies(1)
      errors = %w[VALIDATION_ERROR INTERNAL_ERROR].map { |category| { category: category } }
      [errors, errors.reverse].each do |ordered_errors|
        stub_hubspot_company_batch_read([], errors: ordered_errors)
        expect {
          described_class.new.execute(
            configuration_id: configuration.id,
            reason: "scheduled",
            companies_after: "",
          )
        }.to raise_error(Hubspot::InvalidApiResponse)
        expect(DiscourseCrm::SyncAttempt.last.diagnostics).to include(
          "category" => ["INTERNAL_ERROR"],
        )
        expect(enqueued_args).to be_empty
      end
    end

    it "summarizes unchanged company checks across pages and logs mapped changes per user" do
      reference_companies(3)
      other_user = Fabricate(:user)
      members = [user, other_user, user]
      members.each_with_index do |member, i|
        DiscourseCrm::RecordLink.create!(
          provider: "hubspot",
          account: "12345",
          object: "contact",
          direction: "inbound",
          user_id: member.id,
          external_id: "contact-#{i + 1}",
        )
      end
      companies = (1..3).map { |i| hubspot_company(format("c%03d", i), name: "Acme") }
      stub_hubspot_company_batch_read(companies)
      Hubspot::ContactImport.new(configuration).refresh_companies(companies.pluck("id"))
      stub_hubspot_company_batch_read(
        [companies.first, hubspot_company("c002", name: "Updated")],
        ids: %w[c001 c002],
      )
      stub_hubspot_company_batch_read([companies.last], ids: %w[c003])
      stub_const(Hubspot::Api, :PAGE_SIZE, 2) do
        described_class.new.execute(
          configuration_id: configuration.id,
          reason: "scheduled",
          companies_after: "",
          started_at: Time.current.iso8601,
        )
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
      expect(company_data.fetch("c002")).to eq("name" => "Updated")
    end

    it "records one company refresh for a user with multiple linked contacts" do
      reference_companies(2)
      [1, 2].each do |id|
        DiscourseCrm::RecordLink.create!(
          provider: "hubspot",
          account: "12345",
          object: "contact",
          direction: "inbound",
          user_id: user.id,
          external_id: "contact-#{id}",
        )
      end
      stub_hubspot_company_batch_read(
        [hubspot_company("c001", name: "Acme"), hubspot_company("c002", name: "Other")],
        ids: %w[c001 c002],
      )
      described_class.new.execute(
        configuration_id: configuration.id,
        reason: "scheduled",
        companies_after: "",
      )
      expect(DiscourseCrm::SyncAttempt.sole).to have_attributes(
        user_id: user.id,
        reason: "imported_company",
        diagnostics: {
        },
      )
    end

    it "summarizes missing company checks from the first scheduled pull while recording company changes" do
      configuration.update!(last_synced_at: nil)
      Fabricate(:secondary_email, user: user, email: "other@example.org")
      contacts = [
        hubspot_contact(501, user.email, associatedcompanyid: "c001"),
        hubspot_contact(502, "other@example.org", associatedcompanyid: "c002"),
      ]
      stub_hubspot_contact_list(contacts)
      stub_hubspot_company_batch_read(
        [hubspot_company("c001", name: "Acme")],
        errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: ["c002"] } }],
      )

      started_at = Time.current.change(usec: 0)
      args = {
        configuration_id: configuration.id,
        reason: "scheduled",
        started_at: started_at.iso8601,
      }
      described_class.new.execute(args)
      described_class.new.execute(enqueued_args.last.symbolize_keys)
      described_class.new.execute(
        args.merge(companies_after: "", started_at: (started_at + 1.hour).iso8601),
      )

      attempts = DiscourseCrm::SyncAttempt.where(configuration_id: configuration.id)
      expect(attempts.where(user_id: user.id).order(:id).pluck(:reason)).to eq(
        %w[imported imported_company],
      )
      expect(attempts.where(user_id: nil).order(:created_at).pluck(:reason, :diagnostics)).to eq(
        [
          ["missing_companies_summary", { "count" => 1 }],
          ["missing_companies_summary", { "count" => 1 }],
        ],
      )
      expect(configuration.records.count).to eq(2)
      expect(company_data).to eq("c001" => { "name" => "Acme" })
    end

    it "counts the same missing companies whether they are fetched together or on separate pages" do
      reference_companies(2)
      ids = %w[c001 c002]
      ids.size.times do |index|
        DiscourseCrm::RecordLink.create!(
          provider: "hubspot",
          account: "12345",
          object: "contact",
          direction: "inbound",
          user_id: user.id,
          external_id: "contact-#{index + 1}",
        )
      end
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
            companies_after: "",
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

    it "refreshes referenced companies one chunk at a time after the last page of a scheduled run" do
      freeze_time Time.utc(2026, 11, 2, 12)
      reference_companies(101)
      stub_hubspot_contact_search([])
      (1..101)
        .map { |index| format("c%03d", index) }
        .each_slice(100) do |ids|
          stub_hubspot_company_batch_read(
            [],
            ids: ids,
            errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: ids } }],
          )
        end

      described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

      expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 1, 12))
      expect(enqueued_args).to eq(
        [
          {
            "configuration_id" => configuration.id,
            "reason" => "scheduled",
            "started_at" => Time.zone.now.iso8601,
            "companies_after" => "",
          },
        ],
      )

      described_class.new.execute(enqueued_args.first.symbolize_keys)
      expect(enqueued_args.last["companies_after"]).to eq("c100")
      described_class.new.execute(enqueued_args.last.symbolize_keys)
      expect(enqueued_args.last["companies_after"]).to eq("c101")
      expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 1, 12))

      described_class.new.execute(enqueued_args.last.symbolize_keys)

      expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
      expect(company_batch_of(100)).to have_been_made.once
      expect(company_batch_of(1)).to have_been_made.once
      expect(enqueued_args.size).to eq(3)
    end

    it "retries only the rate limited company chunk" do
      reference_companies(1)
      stub_request(:post, hubspot_url("objects/companies/batch/read")).to_return(
        status: 429,
        headers: {
          "Retry-After" => "9",
        },
      )
      freeze_time

      described_class.new.execute(
        configuration_id: configuration.id,
        reason: "scheduled",
        started_at: Time.zone.now.iso8601,
        companies_after: "",
      )

      job = Jobs::Hubspot::SyncConfiguration.jobs.sole
      expect(job["at"] - Time.now.to_f).to be_within(1).of(9)
      expect(job["args"].first).to include("companies_after" => "")
      expect(a_request(:post, hubspot_url("objects/contacts/search"))).not_to have_been_made
    end

    it "records a failing company chunk on the configuration without moving the sync time" do
      reference_companies(1)
      stub_request(:post, hubspot_url("objects/companies/batch/read")).to_return(
        status: 500,
        body: "boom",
      )

      expect {
        described_class.new.execute(
          configuration_id: configuration.id,
          reason: "scheduled",
          started_at: Time.zone.now.iso8601,
          companies_after: "",
        )
      }.to raise_error(Hubspot::InvalidApiResponse)

      expect(configuration.reload.slice(:last_synced_at, :last_error)).to eq(
        "last_synced_at" => Time.utc(2026, 11, 1, 12),
        "last_error" => "Hubspot::InvalidApiResponse",
      )
      expect(enqueued_args).to be_empty
    end

    it "enters the company phase after a search window restart finishes" do
      freeze_time Time.utc(2026, 11, 2, 12)
      stub_hubspot_contact_search([])

      described_class.new.execute(
        configuration_id: configuration.id,
        reason: "scheduled",
        since: Time.utc(2026, 11, 2, 9, 30).iso8601,
        started_at: Time.zone.now.iso8601,
      )

      expect(enqueued_args.sole).to include("companies_after" => "")
    end

    it "skips the company phase on a backfill" do
      freeze_time Time.utc(2026, 11, 2, 12)
      reference_companies(1)
      stub_hubspot_contact_list([])

      described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

      expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
      expect(enqueued_args).to be_empty
      expect(a_request(:post, hubspot_url("objects/companies/batch/read"))).not_to have_been_made
    end
  end

  it "records an unmatched pull once, even when its last page is empty" do
    stub_hubspot_contact_list([hubspot_contact(123, "unmatched@example.com")], after: "100")
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    stub_hubspot_contact_list([], query: { after: "100" })
    described_class.new.execute(enqueued_args.last.symbolize_keys)
    expect(DiscourseCrm::SyncAttempt.sole).to have_attributes(
      user_id: nil,
      reason: "no_matching_users",
    )
  end

  it "finishes a scheduled run without a company phase when only contact properties are selected" do
    freeze_time Time.utc(2026, 11, 2, 12)
    configuration.update!(last_synced_at: Time.utc(2026, 11, 1, 12))
    stub_hubspot_contact_search([])

    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")

    expect(configuration.reload.last_synced_at).to eq_time(Time.utc(2026, 11, 2, 12))
    expect(DiscourseCrm::SyncAttempt.sole).to have_attributes(
      user_id: nil,
      reason: "no_contacts",
      outcome: "success",
    )
    expect(enqueued_args).to be_empty
  end

  it "does nothing for inactive configurations, disabled reasons or a disabled provider" do
    SiteSetting.hubspot_portal_id = "99999"
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    SiteSetting.hubspot_portal_id = "12345"
    configuration.update!(schedule: "manual", backfill: false)
    described_class.new.execute(configuration_id: configuration.id, reason: "scheduled")
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")
    configuration.update!(schedule: "daily", backfill: true)
    SiteSetting.hubspot_enabled = false
    described_class.new.execute(configuration_id: configuration.id, reason: "backfill")

    expect(a_request(:any, /api.hubapi.com/)).not_to have_been_made
  end
end
