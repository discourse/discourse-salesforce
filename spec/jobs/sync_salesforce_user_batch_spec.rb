# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::SyncSalesforceUserBatch do
  include_context "with salesforce spec helper"

  fab!(:group)
  fab!(:user) { Fabricate(:user, name: "Alex Morgan") }
  fab!(:other_user) { Fabricate(:user, name: "Maya Chen") }
  let!(:configuration) do
    Fabricate(
      :sync_configuration,
      groups: [group],
      object: "Contact",
      account: instance_url,
      mappings: [
        { "source" => "last", "destination" => "LastName", "policy" => "keep" },
        {
          "source" => "static",
          "value" => "Discourse",
          "destination" => "LeadSource",
          "policy" => "overwrite",
        },
      ],
    )
  end
  let(:fields) do
    %w[Email LastName LeadSource].map do |name|
      { name: name, type: "string", createable: true, updateable: true }
    end
  end
  let(:collection_url) { "#{instance_url}services/data/v49.0/composite/sobjects" }

  before do
    SiteSetting.enable_guided_sync_configuration = true
    user.activate
    other_user.activate
    group.add(user)
    group.add(other_user)
    stub_request(:get, "#{api_path}/Contact/describe").to_return(body: { fields: fields }.to_json)
    Jobs::SyncSalesforceUser.clear
  end

  def run_batch
    described_class.new.execute(
      configuration_id: configuration.id,
      user_ids: [user.id, other_user.id],
      reason: "backfill",
    )
  end

  it "preserves a configuration failure when no batch members are still eligible" do
    group.remove(user)
    group.remove(other_user)
    failed_at = 1.hour.ago.change(usec: 0)
    configuration.update!(last_error: "Previous failure", last_error_at: failed_at)

    expect { run_batch }.not_to change(DiscourseCrm::SyncAttempt, :count)

    expect(configuration.reload.last_error).to eq("Previous failure")
    expect(configuration.last_error_at).to eq_time(failed_at)
  end

  it "retries only the failed batch members when backfill is disabled" do
    configuration.update!(schedule: "manual", backfill: false)
    Salesforce::ConfiguredUserBatchSync.stubs(:sync).raises(Salesforce::InvalidCredentials)
    expect {
      described_class.new.execute(
        configuration_id: configuration.id,
        user_ids: [user.id],
        reason: "change",
      )
    }.to raise_error(Salesforce::InvalidCredentials)
    expect(configuration.sync_states.pluck(:user_id)).to eq([user.id])
    described_class.clear
    Jobs::DiscourseCrm::SyncOutboundConfiguration.clear

    DiscourseCrm::ConfigurationScheduler.configuration_saved(
      configuration.reload,
      group_ids_changed: false,
    )

    expect(Jobs::DiscourseCrm::SyncOutboundConfiguration.jobs).to be_empty
    expect(described_class.jobs.map { |job| job["args"].first }).to contain_exactly(
      hash_including("user_ids" => [user.id], "reason" => "retry"),
    )
  end

  it "records completed attempts when the configuration was removed during the CRM call" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    stub_request(:post, collection_url).to_return do
      configuration.destroy!
      {
        status: 200,
        body: [
          { id: "003000000000001", success: true, errors: [] },
          { success: false, errors: [{ statusCode: "INVALID_EMAIL_ADDRESS" }] },
        ].to_json,
      }
    end
    run_batch
    expect(user.reload.salesforce_contact_id).to eq("003000000000001")
    expect(
      DiscourseCrm::SyncAttempt.where(configuration_id: configuration.id).pluck(:user_id, :outcome),
    ).to contain_exactly([user.id, "success"], [other_user.id, "failed"])
    expect(DiscourseCrm::SyncState.where(configuration_id: configuration.id)).to be_empty
  end

  it "only records failures for eligible members of a failed batch" do
    group.remove(other_user)
    stub_request(:get, "#{api_path}/Contact/describe").to_return(status: 503)
    expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse)
    expect(DiscourseCrm::SyncAttempt.pluck(:user_id, :outcome)).to eq([[user.id, "failed"]])
  end

  it "excludes an unconfirmed email while syncing verified users" do
    user.email_tokens.delete_all
    user.email_tokens.create!(email: user.email, scope: EmailToken.scopes[:signup])
    expect(user.reload).to be_active
    expect(user.email_confirmed?).to eq(false)
    lookup =
      stub_request(:get, query_path).with(
        query: {
          q:
            "SELECT Id,Email,LastName,LeadSource FROM Contact WHERE Email IN ('#{other_user.email}')",
        },
      ).to_return(body: { records: [] }.to_json)
    create =
      stub_request(:post, collection_url)
        .with do |request|
          JSON.parse(request.body)["records"].map { |record| record["Email"] } == [other_user.email]
        end
        .to_return(body: [{ id: "003000000000002", success: true }].to_json)

    run_batch

    expect(lookup).to have_been_requested.once
    expect(create).to have_been_requested.once
    expect(user.reload.salesforce_contact_id).to be_nil
    expect(other_user.reload.salesforce_contact_id).to eq("003000000000002")
  end

  it "pins email matches before a failed batch update and reconciles them after an email change" do
    other_user.update!(active: false)
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [{ Id: "contact1", Email: user.email, LastName: "Morgan", LeadSource: "Web" }],
      }.to_json,
    )
    stub_request(:patch, collection_url).to_timeout
    DiscourseCrm::SyncState.store(configuration.id, user.id, fingerprint: "previous")

    run_batch

    expect(configuration.record_link_for(user.id).external_id).to eq("contact1")
    expect(user.reload.salesforce_contact_id).to be_nil
    expect(
      DiscourseCrm::SyncState.find_by(configuration: configuration, user_id: user.id).fingerprint,
    ).to eq("previous")
    user.primary_email.update!(email: "changed@example.com")
    user.reload.activate
    stub_request(:get, "#{api_path}/Contact/contact1").to_return(
      body: { Id: "contact1", LastName: "Morgan", LeadSource: "Web" }.to_json,
    )
    update = stub_request(:patch, "#{api_path}/Contact/contact1").to_return(status: 204)

    Jobs::SyncSalesforceUser.new.execute(
      Jobs::SyncSalesforceUser.jobs.first["args"].first.symbolize_keys,
    )

    expect(update).to have_been_requested.once
    expect(a_request(:post, "#{api_path}/Contact")).not_to have_been_made
    expect(user.reload.salesforce_contact_id).to eq("contact1")
  end

  it "sends each user's stored metrics and configured custom field values in the batch" do
    custom_field = Fabricate(:user_field, name: "Role")
    user.custom_fields["user_field_#{custom_field.id}"] = "Engineer"
    user.save_custom_fields
    user.user_stat.update!(posts_read_count: 15)
    other_user.custom_fields["user_field_#{custom_field.id}"] = "Designer"
    other_user.save_custom_fields
    other_user.user_stat.update!(posts_read_count: 30)
    configuration.update!(
      mappings:
        configuration.mappings +
          [
            { "source" => "posts_read", "destination" => "Posts_Read__c", "policy" => "overwrite" },
            {
              "source" => "user_field_#{custom_field.id}",
              "destination" => "Role__c",
              "policy" => "overwrite",
            },
          ],
    )
    fields.concat(
      [
        { name: "Posts_Read__c", type: "double", createable: true, updateable: true },
        { name: "Role__c", type: "string", createable: true, updateable: true },
      ],
    )
    stub_request(:get, "#{api_path}/Contact/describe").to_return(body: { fields: fields }.to_json)
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    sent = nil
    stub_request(:post, collection_url)
      .with do |request|
        sent = JSON.parse(request.body)
        true
      end
      .to_return(
        body: [
          { id: "003000000000001", success: true },
          { id: "003000000000002", success: true },
        ].to_json,
      )
    run_batch
    expect(
      sent["records"].map { |record| record.slice("Email", "Posts_Read__c", "Role__c") },
    ).to eq(
      [
        { "Email" => user.email, "Posts_Read__c" => 15, "Role__c" => "Engineer" },
        { "Email" => other_user.email, "Posts_Read__c" => 30, "Role__c" => "Designer" },
      ],
    )
  end

  it "batches reads and creates, saves links, and skips unchanged records on retry" do
    fields.find { |field| field[:name] == "LastName" }[:encrypted] = true
    stub_request(:get, "#{api_path}/Contact/describe").to_return(body: { fields: fields }.to_json)
    query =
      "SELECT Id,Email,LastName,LeadSource FROM Contact WHERE Email IN ('#{user.email}','#{other_user.email}')"
    lookup =
      stub_request(:get, query_path).with(query: { q: query }).to_return(
        body: { records: [] }.to_json,
      )
    create =
      stub_request(:post, collection_url).with(
        body: {
          allOrNone: false,
          records: [
            {
              attributes: {
                type: "Contact",
              },
              Email: user.email,
              LastName: "Morgan",
              LeadSource: "Discourse",
            },
            {
              attributes: {
                type: "Contact",
              },
              Email: other_user.email,
              LastName: "Chen",
              LeadSource: "Discourse",
            },
          ],
        },
      ).to_return(
        body: [
          { id: "003000000000001", success: true },
          { id: "003000000000002", success: true },
        ].to_json,
      )
    run_batch
    expect(DiscourseCrm::SyncAttempt.where(outcome: "success").pluck(:diagnostics)).to eq([{}, {}])
    expect(create).to have_been_requested.once
    expect(lookup).to have_been_requested.once
    expect(a_request(:get, "#{api_path}/Contact/describe")).to have_been_requested.once
    expect([user.reload.salesforce_contact_id, other_user.reload.salesforce_contact_id]).to eq(
      %w[003000000000001 003000000000002],
    )
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [
          {
            Id: "003000000000001",
            Email: user.email,
            LastName: "CRM name",
            LeadSource: "Discourse",
          },
          {
            Id: "003000000000002",
            Email: other_user.email,
            LastName: "Chen",
            LeadSource: "Discourse",
          },
        ],
      }.to_json,
    )
    configuration.update!(schedule: "hourly")
    started_at = Time.current.iso8601(6)
    [user, other_user].each do |member|
      described_class.new.execute(
        configuration_id: configuration.id,
        user_ids: [member.id],
        reason: "scheduled",
        scheduled_at: started_at,
      )
    end
    summary = DiscourseCrm::SyncAttempt.where(reason: "unchanged_summary").sole
    expect(summary).to have_attributes(user_id: nil, diagnostics: { "count" => 2 })
    expect(DiscourseCrm::SyncAttempt.where(reason: "unchanged")).to be_empty
    expect(create).to have_been_requested.once
    expect(a_request(:patch, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
  end

  it "only confirms updates whose returned ID matches the submitted record" do
    first_id = "003000000000001"
    second_id = "003000000000002"
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [
          { Id: first_id, Email: user.email, LeadSource: "Web" },
          { Id: second_id, Email: other_user.email, LeadSource: "Web" },
        ],
      }.to_json,
    )
    stub_request(:patch, collection_url).to_return(
      body: [
        { id: "#{first_id}AAA", success: true },
        { id: "003000000000003AAA", success: true },
      ].to_json,
    )
    run_batch
    expect(configuration.record_link_for(user.id).external_id).to eq("#{first_id}AAA")
    expect(configuration.record_link_for(other_user.id).external_id).to eq(second_id)
    expect(DiscourseCrm::SyncAttempt.find_by!(user_id: other_user.id)).to have_attributes(
      outcome: "failed",
      error_class: "Salesforce::ConfiguredUserBatchSync::UnconfirmedCollectionResult",
    )
    expect(DiscourseCrm::SyncAttempt.where(outcome: "success").pluck(:user_id)).to eq([user.id])
    expect(Jobs::SyncSalesforceUser.jobs.sole.fetch("args").first.fetch("user_id")).to eq(
      other_user.id,
    )
  end

  {
    "a malformed ID" => {
      id: "not-a-salesforce-id",
      success: true,
    },
    "a Lead ID for a Contact" => {
      id: "00Q000000000001",
      success: true,
    },
    "a success with a validation error" => {
      id: "003000000000001",
      success: true,
      errors: [{ statusCode: "FIELD_CUSTOM_VALIDATION_EXCEPTION" }],
    },
  }.each do |description, result|
    it "reconciles #{description} while keeping an independently confirmed contact" do
      stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
        body: { records: [] }.to_json,
      )
      stub_request(:post, collection_url).to_return(
        body: [result, { id: "003000000000002", success: true, errors: [] }].to_json,
      )

      run_batch

      expect(configuration.record_link_for(user.id)).to be_nil
      expect(user.reload.salesforce_contact_id).to be_nil
      expect(DiscourseCrm::SyncAttempt.find_by!(user_id: user.id)).to have_attributes(
        outcome: "failed",
        error_class: "Salesforce::ConfiguredUserBatchSync::UnconfirmedCollectionResult",
      )
      expect(other_user.reload.salesforce_contact_id).to eq("003000000000002")
      expect(Jobs::SyncSalesforceUser.jobs.sole.fetch("args").first.fetch("user_id")).to eq(user.id)
    end
  end

  it "reconciles repeated create IDs without linking either user" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    stub_request(:post, collection_url).to_return(
      body: [
        { id: "003000000000001", success: true },
        { id: "003000000000001AAA", success: true },
      ].to_json,
    )
    run_batch
    expect(configuration.record_links).to be_empty
    expect(DiscourseCrm::SyncAttempt.pluck(:outcome)).to eq(%w[failed failed])
    expect(
      Jobs::SyncSalesforceUser.jobs.map { |job| job.fetch("args").first.fetch("user_id") },
    ).to contain_exactly(user.id, other_user.id)
  end

  it "preserves Salesforce values and retries only failed collection entries" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [
          { Id: "003000000000001", Email: user.email, LastName: "CRM name", LeadSource: "Web" },
          { Id: "003000000000002", Email: other_user.email, LastName: "", LeadSource: "Web" },
        ],
      }.to_json,
    )
    update =
      stub_request(:patch, collection_url).with(
        body: {
          allOrNone: false,
          records: [
            { attributes: { type: "Contact" }, Id: "003000000000001", LeadSource: "Discourse" },
            {
              attributes: {
                type: "Contact",
              },
              Id: "003000000000002",
              LastName: "Chen",
              LeadSource: "Discourse",
            },
          ],
        },
      ).to_return(
        body: [
          { id: "003000000000001", success: true },
          { success: false, errors: [{ statusCode: "UNABLE_TO_LOCK_ROW" }] },
        ].to_json,
      )
    run_batch
    expect(update).to have_been_requested.once
    expect(user.reload.salesforce_contact_id).to eq("003000000000001")
    expect(configuration.record_link_for(other_user.id).external_id).to eq("003000000000002")
    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] }).to eq(
      [other_user.id],
    )
  end

  it "defers ambiguous matches and missing linked records to individual jobs" do
    DiscourseCrm::RecordLink.link!(
      provider: "salesforce",
      account: instance_url,
      object: "Contact",
      user_id: other_user.id,
      external_id: "missing",
    )
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [{ Id: "contact1", Email: user.email }, { Id: "contact2", Email: user.email }],
      }.to_json,
    )
    DiscourseCrm::SyncState.store(
      configuration.id,
      other_user.id,
      error: "previous failure",
      fingerprint: "previous fingerprint",
    )
    described_class.new.execute(
      configuration_id: configuration.id,
      user_ids: [user.id, other_user.id],
      reason: "change",
    )
    retry_args =
      Jobs::SyncSalesforceUser
        .jobs
        .map { |job| job["args"].first }
        .find { |args| args["user_id"] == other_user.id }
    expect(retry_args.fetch("reason")).to eq("retry")
    expect(configuration.sync_states.find_by!(user_id: other_user.id).error).to eq(
      "previous failure",
    )
    expect(DiscourseCrm::SyncAttempt.find_by!(user_id: other_user.id).reason).to eq(
      "skipped_reconciliation",
    )
    expect(
      Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] },
    ).to contain_exactly(user.id, other_user.id)
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(a_request(:patch, collection_url)).not_to have_been_made
  end

  it "reconciles linked converted Leads without retrying or recreating them" do
    configuration.update!(
      object: "Lead",
      mappings: [
        { "source" => "last", "destination" => "LastName", "policy" => "keep" },
        {
          "source" => "static",
          "value" => "Unknown",
          "destination" => "Company",
          "policy" => "overwrite",
        },
      ],
    )
    lead_fields =
      %w[Email LastName Company].map do |name|
        { name: name, type: "string", createable: true, updateable: true }
      end
    stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: lead_fields }.to_json)
    lead_id = "00Qbm00000v6wJpEAI"
    DiscourseCrm::RecordLink.link!(
      provider: "salesforce",
      account: instance_url,
      object: "Lead",
      user_id: user.id,
      external_id: lead_id,
    )
    query =
      stub_request(:get, query_path).with(
        query: hash_including("q" => /Email IN .* OR Id IN \('#{lead_id}'\)/),
      ).to_return(
        body: {
          records: [
            {
              Id: lead_id,
              Email: user.email,
              LastName: "Morgan",
              Company: "Unknown",
              IsConverted: true,
              ConvertedContactId: "contact-123",
            },
            {
              Id: "lead-converted-other",
              Email: other_user.email,
              IsConverted: true,
              ConvertedContactId: "contact-other",
            },
          ],
        }.to_json,
      )

    run_batch

    expect(query).to have_been_requested.once
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(a_request(:patch, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
    expect(user.reload.salesforce_lead_id).to be_nil
    expect(user.salesforce_contact_id).to eq("contact-123")
    expect(other_user.reload.salesforce_lead_id).to be_nil
    expect(other_user.salesforce_contact_id).to eq("contact-other")
    expect(configuration.record_link_for(user.id).converted_to_id).to eq("contact-123")
  end

  it "creates Leads only for batch members without an existing Contact" do
    configuration.update!(
      object: "Lead",
      mappings: [
        { "source" => "last", "destination" => "LastName", "policy" => "keep" },
        {
          "source" => "static",
          "value" => "Unknown",
          "destination" => "Company",
          "policy" => "keep",
        },
      ],
    )
    lead_fields =
      %w[Email LastName Company].map do |name|
        { name: name, type: "string", createable: true, updateable: true }
      end
    stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: lead_fields }.to_json)
    stub_request(:get, query_path).with(
      query: hash_including("q" => /FROM Lead WHERE Email IN/),
    ).to_return(body: { records: [] }.to_json)
    contact_lookup =
      stub_request(:get, query_path).with(
        query: {
          q: "SELECT Email FROM Contact WHERE Email IN ('#{user.email}','#{other_user.email}')",
        },
      ).to_return(
        body: {
          records: [],
          nextRecordsUrl: "/services/data/v49.0/query/contacts-next-page",
        }.to_json,
      )
    contact_page =
      stub_request(:get, "#{query_path}contacts-next-page").to_return(
        body: { records: [{ Email: user.email.upcase }, { Email: user.email }] }.to_json,
      )
    create =
      stub_request(:post, collection_url).with(
        body: {
          allOrNone: false,
          records: [
            {
              attributes: {
                type: "Lead",
              },
              Email: other_user.email,
              LastName: "Chen",
              Company: "Unknown",
            },
          ],
        },
      ).to_return(body: [{ id: "00Q000000000002", success: true }].to_json)

    run_batch

    expect(contact_lookup).to have_been_requested.once
    expect(contact_page).to have_been_requested.once
    expect(create).to have_been_requested.once
    expect(user.reload.salesforce_lead_id).to be_nil
    expect(user.salesforce_contact_id).to be_nil
    expect(configuration.record_link_for(user.id)).to be_nil
    expect(other_user.reload.salesforce_lead_id).to eq("00Q000000000002")
    expect(DiscourseCrm::SyncAttempt.find_by(user_id: user.id)).to have_attributes(
      outcome: "skipped",
      reason: "skipped_existing_contact",
    )
    expect(DiscourseCrm::SyncAttempt.find_by(user_id: other_user.id)).to have_attributes(
      outcome: "success",
      reason: "created",
    )
    expect(a_request(:patch, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
  end

  context "when checking Contacts before creating Leads" do
    before do
      configuration.update!(
        object: "Lead",
        mappings: [
          { "source" => "last", "destination" => "LastName", "policy" => "keep" },
          {
            "source" => "static",
            "value" => "Unknown",
            "destination" => "Company",
            "policy" => "keep",
          },
        ],
      )
      lead_fields =
        %w[Email LastName Company].map do |name|
          { name: name, type: "string", createable: true, updateable: true }
        end
      stub_request(:get, "#{api_path}/Lead/describe").to_return(
        body: { fields: lead_fields }.to_json,
      )
    end

    it "clears a saved fingerprint for a Contact match so later changes can create a Lead" do
      DiscourseCrm::SyncState.store(
        configuration.id,
        user.id,
        fingerprint: "previous",
        error: "previous-error",
      )
      stub_request(:get, query_path).with(
        query: hash_including("q" => /FROM Lead WHERE/),
      ).to_return(body: { records: [] }.to_json)
      stub_request(:get, query_path).with(
        query: hash_including("q" => /SELECT Email FROM Contact WHERE/),
      ).to_return(body: { records: [{ Email: user.email }, { Email: other_user.email }] }.to_json)

      run_batch

      state = DiscourseCrm::SyncState.find_by!(configuration: configuration, user_id: user.id)
      expect(state.fingerprint).to be_nil
      expect(state.error).to be_nil
      expect(a_request(:post, collection_url)).not_to have_been_made
      stub_salesforce_person_lookup("Lead", user.email, fields: %w[LastName Company])
      stub_salesforce_converted_lead_lookup(user.email)
      stub_salesforce_person_lookup("Contact", user.email)
      create =
        stub_request(:post, "#{api_path}/Lead").to_return(
          status: 201,
          body: { id: "new-lead" }.to_json,
        )

      Jobs::SyncSalesforceUser.new.execute(
        configuration_id: configuration.id,
        user_id: user.id,
        reason: "change",
      )

      expect(create).to have_been_requested.once
      expect(state.reload.fingerprint).to be_present
    end

    [503, 400].each do |status|
      it "updates existing Leads but does not create Leads when Contact lookup returns #{status}" do
        stub_request(:get, query_path).with(
          query: hash_including("q" => /FROM Lead WHERE/),
        ).to_return(
          body: {
            records: [
              { Id: "00Q000000000002", Email: other_user.email, LastName: "Chen", Company: nil },
            ],
          }.to_json,
        )
        stub_request(:get, query_path).with(
          query: {
            q: "SELECT Email FROM Contact WHERE Email IN ('#{user.email}')",
          },
        ).to_return(status: status, body: [{ errorCode: "INVALID_TYPE" }].to_json)
        update =
          stub_request(:patch, collection_url).with(
            body: {
              allOrNone: false,
              records: [
                { attributes: { type: "Lead" }, Id: "00Q000000000002", Company: "Unknown" },
              ],
            },
          ).to_return(body: [{ id: "00Q000000000002", success: true }].to_json)

        expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse)

        expect(update).to have_been_requested.once
        expect(other_user.reload.salesforce_lead_id).to eq("00Q000000000002")
        expect(a_request(:post, collection_url)).not_to have_been_made
        expect(configuration.reload.last_error).to eq("Salesforce::InvalidApiResponse")
      end
    end

    it "does not create Leads when a Contact page fails and rechecks on retry" do
      stub_request(:get, query_path).with(
        query: hash_including("q" => /FROM Lead WHERE/),
      ).to_return(body: { records: [] }.to_json)
      lookup =
        stub_request(:get, query_path).with(
          query: hash_including("q" => /SELECT Email FROM Contact WHERE/),
        ).to_return(
          body: {
            records: [{ Email: user.email }],
            nextRecordsUrl: "/services/data/v49.0/query/contact-page",
          }.to_json,
        )
      page =
        stub_request(:get, "#{query_path}contact-page")
          .to_return(status: 503)
          .then
          .to_return(body: { records: [{ Email: other_user.email }] }.to_json)

      expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse)
      expect(a_request(:post, collection_url)).not_to have_been_made
      run_batch

      expect(lookup).to have_been_requested.twice
      expect(page).to have_been_requested.twice
      expect(a_request(:post, collection_url)).not_to have_been_made
      expect(configuration.reload.last_error).to be_nil
    end
  end

  it "checks Contacts in chunks of 25 emails for Lead creation" do
    configuration.update!(
      object: "Lead",
      mappings: [
        { "source" => "last", "destination" => "LastName", "policy" => "keep" },
        {
          "source" => "static",
          "value" => "Unknown",
          "destination" => "Company",
          "policy" => "keep",
        },
      ],
    )
    fields << { name: "Company", type: "string", createable: true, updateable: true }
    stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: fields }.to_json)
    members = [user, other_user] + Fabricate.times(24, :user)
    members.each do |member|
      member.activate
      group.add(member)
    end
    stub_request(:get, query_path).with(
      query: hash_including("q" => /FROM Lead WHERE Email IN/),
    ).to_return(body: { records: [] }.to_json)
    lookups =
      members
        .each_slice(25)
        .map do |batch|
          emails = batch.map { |member| "'#{member.email}'" }.join(",")
          stub_request(:get, query_path).with(
            query: {
              q: "SELECT Email FROM Contact WHERE Email IN (#{emails})",
            },
          ).to_return(body: { records: batch.map { |member| { Email: member.email } } }.to_json)
        end

    described_class.new.execute(
      configuration_id: configuration.id,
      user_ids: members.map(&:id),
      reason: "backfill",
    )

    lookups.each { |lookup| expect(lookup).to have_been_requested.once }
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(a_request(:patch, collection_url)).not_to have_been_made
    expect(configuration.record_links).to be_empty
  end

  it "summarizes repeated scheduled skips for converted leads and records each recovery" do
    configuration.update!(object: "Lead")
    [user, other_user].each do |member|
      DiscourseCrm::RecordLink.mark_converted!(
        provider: "salesforce",
        account: instance_url,
        object: "Lead",
        user_id: member.id,
        external_id: "lead-#{member.id}",
        to_object: "Contact",
        to_id: "contact-#{member.id}",
      )
    end

    scheduled_batch = {
      configuration_id: configuration.id,
      user_ids: [user.id, other_user.id],
      reason: "scheduled",
    }
    described_class.new.execute(scheduled_batch.merge(scheduled_at: 1.hour.ago.iso8601(6)))
    configuration.record_result(other_user.id, error: StandardError.new)
    described_class.new.execute(scheduled_batch.merge(scheduled_at: Time.current.iso8601(6)))

    attempts = DiscourseCrm::SyncAttempt.where(configuration_id: configuration.id)
    expect(attempts.where(user_id: user.id).pluck(:reason)).to eq(["skipped_converted"])
    expect(attempts.where(user_id: other_user.id).order(:id).pluck(:reason)).to eq(
      %w[skipped_converted failed skipped_converted],
    )
    expect(attempts.where(user_id: nil).sole).to have_attributes(
      reason: "skipped_converted_summary",
      outcome: "skipped",
      diagnostics: {
        "count" => 1,
      },
    )

    expect(a_request(:get, %r{/sobjects/Lead/describe})).not_to have_been_made
    expect(a_request(:get, query_path)).not_to have_been_made
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(a_request(:patch, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
  end

  it "keeps checks from an undated batch separate from retries of a timestamped run" do
    freeze_time(Time.current.change(nsec: 0))
    scheduled_at = 5.minutes.ago
    configuration.update!(object: "Lead", last_scheduled_at: scheduled_at)
    DiscourseCrm::RecordLink.mark_converted!(
      provider: "salesforce",
      account: instance_url,
      object: "Lead",
      user_id: user.id,
      external_id: "lead-1",
      to_object: "Contact",
      to_id: "contact-1",
    )
    configuration.record_result(user.id, reason: "skipped_converted")
    batch = { configuration_id: configuration.id, user_ids: [user.id], reason: "scheduled" }

    2.times { described_class.new.execute(batch.merge(scheduled_at: scheduled_at.iso8601(6))) }
    described_class.new.execute(batch)

    summaries =
      DiscourseCrm::SyncAttempt.where(
        configuration_id: configuration.id,
        reason: "skipped_converted_summary",
      )
    expect(summaries.order(:created_at).pluck(:created_at, :diagnostics)).to eq(
      [[scheduled_at, { "count" => 2 }], [Time.current, { "count" => 1 }]],
    )
  end

  it "rechecks membership and configuration activation before making requests" do
    group.remove(user)
    other_user.update!(active: false)
    run_batch
    configuration.update!(active: false)
    group.add(user)
    run_batch
    expect(a_request(:get, "#{api_path}/Contact/describe")).not_to have_been_made
  end

  it "follows query pages and uses saved IDs after an email change" do
    DiscourseCrm::RecordLink.link!(
      provider: "salesforce",
      account: instance_url,
      object: "Contact",
      user_id: user.id,
      external_id: "contact1",
    )
    lookup =
      stub_request(:get, query_path).with(
        query: hash_including("q" => /Id IN \(\x27contact1\x27\)/),
      ).to_return(
        body: {
          records: [
            {
              Id: "contact1",
              Email: "old@example.com",
              LastName: "CRM name",
              LeadSource: "Discourse",
            },
          ],
          nextRecordsUrl: "/services/data/v49.0/query/next-page",
        }.to_json,
      )
    page =
      stub_request(:get, "#{query_path}next-page").to_return(
        body: {
          records: [
            { Id: "contact2", Email: other_user.email, LastName: "Chen", LeadSource: "Discourse" },
          ],
        }.to_json,
      )
    run_batch
    expect(lookup).to have_been_requested.once
    expect(page).to have_been_requested.once
    expect(user.reload.salesforce_contact_id).to eq("contact1")
    expect(a_request(:post, collection_url)).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
  end

  it "reconciles individual users after an uncertain collection write without recreating committed records" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    collection = stub_request(:post, collection_url).to_raise(Faraday::TimeoutError)

    run_batch

    expect(DiscourseCrm::SyncAttempt.sole).to have_attributes(
      user_id: nil,
      outcome: "failed",
      error_class: "Faraday::TimeoutError",
    )
    retries = Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first }
    expect(retries.map { |args| args["user_id"] }).to contain_exactly(user.id, other_user.id)
    expect(retries).to all(include("configuration_id" => configuration.id, "reason" => "backfill"))
    expect(configuration.sync_states.where.not(error: nil).pluck(:user_id)).to contain_exactly(
      user.id,
      other_user.id,
    )
    expect(configuration.reload.last_error).to be_nil

    stub_salesforce_person_lookup(
      "Contact",
      user.email,
      fields: %w[LastName LeadSource],
      record: {
        Id: "committed",
        LastName: "Morgan",
        LeadSource: "Discourse",
      },
    )
    stub_salesforce_person_lookup(
      "Contact",
      other_user.email,
      fields: %w[LastName LeadSource],
      records: [],
    )
    create =
      stub_request(:post, "#{api_path}/Contact").with(
        body: {
          Email: other_user.email,
          LastName: "Chen",
          LeadSource: "Discourse",
        },
      ).to_return(status: 201, body: { id: "new-contact" }.to_json)

    retries.each { |args| Jobs::SyncSalesforceUser.new.execute(args.deep_symbolize_keys) }

    expect(user.reload.salesforce_contact_id).to eq("committed")
    expect(other_user.reload.salesforce_contact_id).to eq("new-contact")
    expect(collection).to have_been_requested.once
    expect(create).to have_been_requested.once
    expect(configuration.reload.sync_status["error"]).to be_nil
  end

  ["not JSON", { unexpected: "response" }.to_json].each do |response_body|
    it "queues individual recovery for an uncertain response #{response_body.inspect}" do
      stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
        body: { records: [] }.to_json,
      )
      stub_request(:post, collection_url).to_return(status: 200, body: response_body)

      run_batch

      expect(
        Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] },
      ).to contain_exactly(user.id, other_user.id)
    end
  end

  it "only retries failed updates while still creating other records" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [
          { Id: "003000000000002", Email: other_user.email, LastName: "Chen", LeadSource: nil },
        ],
      }.to_json,
    )
    created =
      stub_request(:post, collection_url).to_return(
        status: 200,
        body: [{ id: "003000000000001", success: true }].to_json,
      )
    stub_request(:patch, collection_url).to_return(status: 503, body: "Unavailable")

    run_batch

    expect(user.reload.salesforce_contact_id).to eq("003000000000001")
    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] }).to eq(
      [other_user.id],
    )
    expect(created).to have_been_requested.once
  end

  it "queues individual recovery after a connection failure during a write" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    stub_request(:post, collection_url).to_raise(Faraday::ConnectionFailed)

    run_batch

    expect(
      Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["user_id"] },
    ).to contain_exactly(user.id, other_user.id)
  end

  it "keeps authentication, permission and rate-limit write failures on the batch retry path" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: { records: [] }.to_json,
    )
    [401, 403, 429].each do |status|
      stub_request(:post, collection_url).to_return(status: status, body: "Rejected")

      expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse) { |error|
        expect(error.status).to eq(status)
      }
      expect(Jobs::SyncSalesforceUser.jobs).to be_empty
    end
  end

  it "preserves a successful update when creating another contact fails" do
    DiscourseCrm::SyncConfiguration.record_result(
      configuration.id,
      user.id,
      error: Salesforce::InvalidCredentials.new,
    )
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      body: {
        records: [
          { Id: "003000000000002", Email: user.email, LastName: "Morgan", LeadSource: "Web" },
        ],
      }.to_json,
    )
    stub_request(:patch, collection_url).to_return(
      body: [{ id: "003000000000002", success: true }].to_json,
    )
    stub_request(:post, collection_url).to_return(status: 403, body: "Rejected")

    expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse)

    expect(user.reload.salesforce_contact_id).to eq("003000000000002")
    expect(configuration.sync_states.find_by!(user_id: user.id).error).to be_nil
    expect(configuration.sync_states.where.not(error: nil).pluck(:user_id)).to eq([other_user.id])
    expect(configuration.reload.last_error).to eq("Salesforce::InvalidApiResponse")
  end

  it "records invalid mappings without retrying the batch" do
    configuration.update!(mappings: [])

    expect { run_batch }.not_to raise_error

    expect(configuration.reload.last_error).to eq("Discourse::InvalidParameters")
    expect(a_request(:get, query_path)).not_to have_been_made
  end

  it "records one shared lookup failure for each batch attempt and keeps both users eligible for retry" do
    stub_request(:get, query_path).with(query: hash_including("q" => /SELECT/)).to_return(
      status: 503,
      body: "Unavailable",
    )

    2.times { expect { run_batch }.to raise_error(Salesforce::InvalidApiResponse) }
    expect(DiscourseCrm::SyncAttempt.pluck(:user_id, :outcome)).to eq(
      [[nil, "failed"], [nil, "failed"]],
    )
    expect(configuration.reload.last_error).to eq("Salesforce::InvalidApiResponse")
    expect(configuration.sync_states.where.not(error: nil).pluck(:user_id)).to contain_exactly(
      user.id,
      other_user.id,
    )
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
    expect(a_request(:post, collection_url)).not_to have_been_made
  end
end
