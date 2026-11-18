# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::Hubspot::PushUser do
  include_context "with hubspot spec helper"

  fab!(:user) { Fabricate(:verified_user, name: "Alex Morgan") }
  fab!(:group)

  let!(:configuration) do
    Fabricate(
      :sync_configuration,
      provider: "hubspot",
      account: "12345",
      object: "contact",
      groups: [group],
      mappings: [
        { "source" => "first", "destination" => "firstname", "policy" => "keep" },
        { "source" => "last", "destination" => "lastname", "policy" => "overwrite" },
        {
          "source" => "static",
          "destination" => "community_source",
          "value" => "Discourse",
          "policy" => "keep",
        },
      ],
    )
  end

  before do
    SiteSetting.salesforce_enabled = false
    SiteSetting.enable_guided_sync_configuration = true
    group.add(user)
  end

  def run_sync(reason = "backfill")
    described_class.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: reason,
    )
  end

  def stub_contact(record = nil, status: 200)
    stub_request(:get, "#{hubspot_url}/objects/contacts/#{ERB::Util.url_encode(user.email)}").with(
      query: {
        idProperty: "email",
        properties: "firstname,lastname,community_source",
      },
    ).to_return(status: status, body: record.to_json)
  end

  def stub_batch_contacts(records = [])
    stub_request(:post, "#{hubspot_url}/objects/contacts/batch/read").to_return(
      body: { status: "COMPLETE", results: records }.to_json,
    )
  end

  def stub_batch_create
    stub_request(:post, "#{hubspot_url}/objects/contacts/batch/create").to_return(
      body: {
        status: "COMPLETE",
        results: [{ id: "42", properties: { email: user.email } }],
      }.to_json,
    )
  end

  it "schedules failed first pushes but excludes permanent errors and unrelated users" do
    configuration.update!(backfill: false, schedule: "hourly")
    recoverable =
      [
        Hubspot::DailyQuotaExceeded.new,
        Hubspot::InvalidCredentials.new,
        Hubspot::InvalidApiResponse.new("Unavailable", status: 503),
      ].map do |error|
        member = Fabricate(:verified_user)
        group.add(member)
        DiscourseCrm::SyncConfiguration.record_result(configuration.id, member.id, error: error)
        member.id
      end
    [
      Hubspot::InvalidPropertyValue.new("firstname"),
      Hubspot::ApiValidationError.new(status: 400),
      Hubspot::MissingContact.new,
      Discourse::InvalidParameters.new(:mappings),
    ].each do |error|
      member = Fabricate(:verified_user)
      group.add(member)
      DiscourseCrm::SyncConfiguration.record_result(configuration.id, member.id, error: error)
      if error.is_a?(Hubspot::ApiValidationError)
        DiscourseCrm::RecordLink.link!(
          provider: "hubspot",
          account: "12345",
          object: "contact",
          user_id: member.id,
          external_id: "invalid-contact",
        )
      end
    end
    outsider = Fabricate(:verified_user)
    DiscourseCrm::SyncConfiguration.record_result(
      configuration.id,
      outsider.id,
      error: Hubspot::DailyQuotaExceeded.new,
    )
    Jobs::Hubspot::PushUserBatch.clear

    Jobs::DiscourseCrm::SyncOutboundConfiguration.new.execute(
      configuration_id: configuration.id,
      reason: "scheduled",
    )

    expect(
      Jobs::Hubspot::PushUserBatch.jobs.flat_map { |job| job["args"].first["user_ids"] },
    ).to match_array(recoverable)
  end

  it "creates a contact, stores a HubSpot link and skips unchanged profile events" do
    stub_contact(nil, status: 404)
    request =
      stub_request(:post, "#{hubspot_url}/objects/contacts").with(
        body: {
          properties: {
            email: user.email,
            firstname: "Alex",
            lastname: "Morgan",
            community_source: "Discourse",
          },
        },
      ).to_return(body: { id: "42" }.to_json)

    run_sync
    run_sync("change")

    expect(request).to have_been_requested.once
    expect(configuration.record_link_for(user.id).external_id).to eq("42")
    expect(user.reload.salesforce_contact_id).to be_nil
    expect(configuration.reload.sync_status["error"]).to be_nil
    expect(configuration.last_synced_at).to be_present
  end

  it "retries an unchanged profile event after a scheduled refresh fails" do
    record =
      hubspot_contact(
        "42",
        user.email,
        firstname: "Alex",
        lastname: "Morgan",
        community_source: "Discourse",
      )
    stub_contact(record)
    run_sync("change")
    linked =
      stub_request(:get, "#{hubspot_url}/objects/contacts/42")
        .with(query: { properties: "firstname,lastname,community_source" })
        .to_return(status: 503, body: "unavailable")
        .then
        .to_return(body: record.to_json)

    expect { run_sync("scheduled") }.to raise_error(Hubspot::InvalidApiResponse)
    expect(configuration.reload.sync_status["error"]).to be_present
    run_sync("change")
    run_sync("change")

    expect(linked).to have_been_requested.twice
    expect(configuration.reload.sync_status["error"]).to be_nil
  end

  it "rejects text mapped to a number and sends numeric sources as JSON numbers" do
    stub_request(:get, "#{hubspot_url}/properties/contacts").to_return(
      body: {
        results: hubspot_properties + [{ name: "post_count", label: "Posts", type: "number" }],
      }.to_json,
    )
    mapping = { "source" => "first", "destination" => "post_count", "policy" => "overwrite" }
    configuration.update!(mappings: [mapping])

    run_sync

    expect(configuration.reload.sync_status["error"]).to eq("Discourse::InvalidParameters")
    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
    expect(a_request(:patch, %r{/crm/v3/objects/contacts/})).not_to have_been_made

    configuration.update!(mappings: [mapping.merge("source" => "posts")])
    user.user_stat.update!(post_count: 42)
    stub_request(:get, "#{hubspot_url}/objects/contacts/#{ERB::Util.url_encode(user.email)}").with(
      query: {
        idProperty: "email",
        properties: "post_count",
      },
    ).to_return(status: 404)
    create =
      stub_request(:post, "#{hubspot_url}/objects/contacts")
        .with { |request| JSON.parse(request.body).dig("properties", "post_count") == 42 }
        .to_return(body: { id: "42" }.to_json)

    run_sync

    expect(create).to have_been_requested.once
    expect(configuration.reload.sync_status["error"]).to be_nil
  end

  it "matches by email, preserves CRM values and updates the stable ID after an email change" do
    record = {
      id: "42",
      properties: {
        firstname: "CRM first",
        lastname: "Old",
        community_source: "CRM",
      },
    }
    stub_contact(record)
    request =
      stub_request(:patch, "#{hubspot_url}/objects/contacts/42").with(
        body: { properties: { lastname: "Morgan" } }.to_json,
      ).to_return(body: { id: "42" }.to_json)
    run_sync
    user.update!(name: "Alex Newname")
    user.primary_email.update!(email: "new@example.com")
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        properties: "firstname,lastname,community_source",
      },
    ).to_return(body: record.to_json)
    changed =
      stub_request(:patch, "#{hubspot_url}/objects/contacts/42").with(
        body: { properties: { lastname: "Newname" } }.to_json,
      ).to_return(body: { id: "42" }.to_json)

    run_sync("change")

    expect(request).to have_been_requested.once
    expect(changed).to have_been_requested.once
    expect(configuration.record_link_for(user.id).external_id).to eq("42")
  end

  it "stops pending work when the provider, group, email verification or account is no longer valid" do
    SiteSetting.hubspot_enabled = false
    run_sync
    SiteSetting.hubspot_enabled = true
    SiteSetting.hubspot_portal_id = "different-account"
    run_sync
    SiteSetting.hubspot_portal_id = "12345"
    group.remove(user)
    run_sync
    group.add(user)
    user.email_tokens.delete_all
    user.email_tokens.create!(email: user.email, scope: EmailToken.scopes[:signup])
    run_sync

    expect(a_request(:get, /api.hubapi.com/)).not_to have_been_made
    expect(configuration.record_link_for(user.id)).to be_nil
  end

  it "retains a missing contact until a replacement exists and resumes related configurations" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      user_id: user.id,
      external_id: "42",
    )
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        properties: "firstname,lastname,community_source",
      },
    ).to_return(
      body: {
        id: "42",
        properties: {
          firstname: "Alex",
          lastname: "Morgan",
          community_source: "Discourse",
        },
      }.to_json,
    )
    run_sync
    related =
      Fabricate(
        :sync_configuration,
        provider: "hubspot",
        account: "12345",
        object: "contact",
        groups: [group],
      )
    DiscourseCrm::SyncState.store(related.id, user.id, fingerprint: "previous-contact")
    Hubspot::SyncFailure.record(related.id, user.id, Hubspot::MissingContact.new)
    invalid_mapping =
      Fabricate(
        :sync_configuration,
        provider: "hubspot",
        account: "12345",
        object: "contact",
        groups: [group],
      )
    Hubspot::SyncFailure.record(
      invalid_mapping.id,
      user.id,
      Hubspot::ApiValidationError.new(status: 400),
    )

    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        properties: "firstname,lastname,community_source",
      },
    ).to_return(status: 404, body: "missing")
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        archived: true,
      },
    ).to_return(status: 404, body: "missing")

    stub_contact(nil, status: 404)
    expect { run_sync }.not_to raise_error

    expect(configuration.record_link_for(user.id).external_id).to eq("42")
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::MissingContact")
    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
    expect(related.sync_states.find_by!(user_id: user.id).error).to eq("Hubspot::MissingContact")

    stub_contact(
      {
        id: "43",
        properties: {
          firstname: "Alex",
          lastname: "Morgan",
          community_source: "Discourse",
        },
      },
    )
    run_sync("change")
    expect(configuration.record_link_for(user.id).external_id).to eq("43")
    expect(
      DiscourseCrm::SyncState.find_by(configuration_id: related.id, user_id: user.id).fingerprint,
    ).to be_nil
    expect(configuration.reload.sync_status["error"]).to be_nil
    state = related.sync_states.find_by!(user_id: user.id)
    expect(state.error).to be_nil
    expect(state.error_at).to be_nil
    expect(invalid_mapping.sync_states.find_by!(user_id: user.id).error).to eq(
      "Hubspot::ApiValidationError",
    )
    Jobs::Hubspot::PushUserBatch.clear
    [related, invalid_mapping].each do |config|
      Jobs::DiscourseCrm::SyncOutboundConfiguration.new.execute(
        configuration_id: config.id,
        reason: "scheduled",
      )
    end
    expect(Jobs::Hubspot::PushUserBatch.jobs.map { |job| job["args"].first }).to contain_exactly(
      hash_including("configuration_id" => related.id, "user_ids" => [user.id]),
    )
    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
  end

  it "recreates a confirmed archived contact and invalidates related fingerprints" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      user_id: user.id,
      external_id: "42",
    )
    related =
      Fabricate(
        :sync_configuration,
        provider: "hubspot",
        account: "12345",
        object: "contact",
        active: false,
      )
    other_account =
      Fabricate(:sync_configuration, provider: "hubspot", account: "67890", object: "contact")
    salesforce = Fabricate(:sync_configuration, account: "12345", object: "Contact")
    [configuration, related, other_account, salesforce].each do |config|
      DiscourseCrm::SyncState.store(config.id, user.id, fingerprint: "old")
    end
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        properties: "firstname,lastname,community_source",
      },
    ).to_return(status: 404, body: "missing")
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        archived: true,
      },
    ).to_return(body: { id: "42", archived: true }.to_json)
    lookup = stub_contact(nil, status: 404)
    created =
      stub_request(:post, "#{hubspot_url}/objects/contacts").with(
        body: {
          properties: {
            email: user.email,
            firstname: "Alex",
            lastname: "Morgan",
            community_source: "Discourse",
          },
        },
      ).to_return(body: { id: "43" }.to_json)

    run_sync
    run_sync("change")

    expect(lookup).to have_been_requested.once
    expect(created).to have_been_requested.once
    expect(configuration.record_link_for(user.id).external_id).to eq("43")
    expect(configuration.reload.sync_status["error"]).to be_nil
    expect(
      DiscourseCrm::SyncState.find_by(configuration: related, user_id: user.id).fingerprint,
    ).to be_nil
    [other_account, salesforce].each do |config|
      expect(
        DiscourseCrm::SyncState.find_by(configuration: config, user_id: user.id).fingerprint,
      ).to eq("old")
    end
  end

  it "relinks a confirmed archived contact to an existing email match" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      user_id: user.id,
      external_id: "42",
    )
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        properties: "firstname,lastname,community_source",
      },
    ).to_return(status: 404, body: "missing")
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        archived: true,
      },
    ).to_return(body: { id: "42", archived: true }.to_json)
    lookup =
      stub_contact(
        {
          id: "43",
          properties: {
            firstname: "Alex",
            lastname: "Morgan",
            community_source: "Discourse",
          },
        },
      )

    run_sync

    expect(lookup).to have_been_requested.once
    expect(configuration.record_link_for(user.id).external_id).to eq("43")
    expect(configuration.reload.sync_status["error"]).to be_nil
    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
  end

  it "retries unchanged profile events after replacement creation fails" do
    stub_contact(nil, status: 404)
    stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(body: { id: "42" }.to_json)
    run_sync
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        properties: "firstname,lastname,community_source",
      },
    ).to_return(status: 404, body: "missing")
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        archived: true,
      },
    ).to_return(body: { id: "42", archived: true }.to_json)
    stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(
      status: 503,
      body: "unavailable",
    )

    expect { run_sync }.to raise_error(Hubspot::InvalidApiResponse)
    expect(configuration.record_link_for(user.id)).to be_nil
    expect(
      DiscourseCrm::SyncState.find_by(configuration: configuration, user_id: user.id).fingerprint,
    ).to be_nil

    stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(body: { id: "43" }.to_json)
    run_sync("change")

    expect(configuration.record_link_for(user.id).external_id).to eq("43")
    expect(configuration.reload.sync_status["error"]).to be_nil
  end

  it "retains a link when its archive lookup does not confirm that ID was deleted" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      user_id: user.id,
      external_id: "42",
    )
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        properties: "firstname,lastname,community_source",
      },
    ).to_return(status: 404, body: "missing")
    [{ id: "42", archived: false }, { id: "43", archived: true }].each do |record|
      stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
        query: {
          archived: true,
        },
      ).to_return(body: record.to_json)

      expect { run_sync }.not_to raise_error
      expect(configuration.record_link_for(user.id).external_id).to eq("42")
    end

    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
  end

  it "retains linked contacts on permission and server errors" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      user_id: user.id,
      external_id: "42",
    )
    [400, 403, 408, 423, 503].each do |status|
      stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
        query: {
          properties: "firstname,lastname,community_source",
        },
      ).to_return(status: status, body: "lookup failed")

      if [408, 423, 503].include?(status)
        expect { run_sync }.to raise_error(Hubspot::InvalidApiResponse)
      else
        expect { run_sync }.not_to raise_error
      end
      expect(configuration.record_link_for(user.id).external_id).to eq("42")
    end

    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
    expect(
      a_request(:get, "#{hubspot_url}/objects/contacts/42").with(query: { archived: true }),
    ).not_to have_been_made
  end

  it "queues HubSpot backfills and scheduled refreshes through the shared scheduler" do
    DiscourseCrm::ConfigurationScheduler.enqueue_user(user, reason: "change", inbound: false)
    expect(described_class.jobs.map { |job| job["args"].first }).to include(
      hash_including("configuration_id" => configuration.id, "user_id" => user.id),
    )
    Jobs::DiscourseCrm::SyncOutboundConfiguration.new.execute(
      configuration_id: configuration.id,
      reason: "backfill",
    )
    batch = Jobs::Hubspot::PushUserBatch.jobs.last["args"].first
    described_class.clear
    stub_batch_contacts
    created =
      stub_request(:post, "#{hubspot_url}/objects/contacts/batch/create").to_return(
        body: { results: [{ id: "42", properties: { email: user.email } }] }.to_json,
      )
    Jobs::Hubspot::PushUserBatch.new.execute(batch.symbolize_keys)
    expect(created).to have_been_requested.once
    expect(described_class.jobs).to be_empty
    freeze_time Time.utc(2026, 11, 10, 3)
    DiscourseCrm::ConfigurationScheduler.enqueue_due
    expect(
      Jobs::DiscourseCrm::SyncOutboundConfiguration.jobs.map { |job| job["args"].first },
    ).to include(hash_including("configuration_id" => configuration.id, "reason" => "scheduled"))
  end
  it "syncs false confirmation values to HubSpot single-checkbox properties" do
    confirmation = Fabricate(:user_field, field_type: "confirm")
    user.custom_fields["user_field_#{confirmation.id}"] = "false"
    user.save_custom_fields
    configuration.update!(
      mappings:
        configuration.mappings +
          [
            {
              "source" => "user_field_#{confirmation.id}",
              "destination" => "community_confirmed",
              "policy" => "overwrite",
            },
          ],
    )
    properties =
      hubspot_properties +
        [
          {
            name: "community_confirmed",
            label: "Confirmed",
            type: "enumeration",
            fieldType: "booleancheckbox",
          },
        ]
    stub_request(:get, "#{hubspot_url}/properties/contacts").to_return(
      body: { results: properties }.to_json,
    )
    stub_request(:get, "#{hubspot_url}/objects/contacts/#{ERB::Util.url_encode(user.email)}").with(
      query: {
        idProperty: "email",
        properties: "firstname,lastname,community_source,community_confirmed",
      },
    ).to_return(
      body: {
        id: "42",
        properties: {
          firstname: "Alex",
          lastname: "Morgan",
          community_source: "Discourse",
          community_confirmed: "true",
        },
      }.to_json,
    )
    update =
      stub_request(:patch, "#{hubspot_url}/objects/contacts/42").with(
        body: {
          properties: {
            community_confirmed: false,
          },
        },
      ).to_return(body: { id: "42" }.to_json)

    run_sync

    expect(update).to have_been_requested.once
    expect(configuration.record_link_for(user.id).external_id).to eq("42")
    expect(configuration.reload.sync_status["error"]).to be_nil
  end
  it "records an account mismatch without retrying or changing stored links" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      user_id: user.id,
      external_id: "42",
    )
    SiteSetting.hubspot_access_token = "OTHER_PORTAL_TOKEN"
    stub_request(:post, "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info").with(
      body: {
        tokenKey: "OTHER_PORTAL_TOKEN",
      },
    ).to_return(body: { hubId: 99_999, appId: 6789 }.to_json)

    expect { run_sync }.not_to raise_error
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::InvalidCredentials")
    expect(a_request(:get, %r{/crm/v3/})).not_to have_been_made
    expect(configuration.record_link_for(user.id).external_id).to eq("42")
  end

  it "records daily quota exhaustion without rescheduling the user" do
    stub_contact(nil, status: 404)
    stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(
      status: 429,
      body: { policyName: "DAILY" }.to_json,
    )
    described_class.clear
    expect { run_sync }.not_to raise_error
    expect(described_class.jobs).to be_empty
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::DailyQuotaExceeded")
  end

  it "reschedules a throttled user without clearing an existing failure" do
    DiscourseCrm::SyncConfiguration.record_result(
      configuration.id,
      user.id,
      error: Hubspot::InvalidApiResponse.new,
    )
    stub_request(:get, "#{hubspot_url}/properties/contacts").to_return(
      status: 429,
      headers: {
        "Retry-After" => "30",
      },
    )
    described_class.clear
    freeze_time

    run_sync

    job = described_class.jobs.last
    expect(job["args"].first).to include(
      "configuration_id" => configuration.id,
      "user_id" => user.id,
      "reason" => "backfill",
    )
    expect(job["at"]).to eq(30.seconds.from_now.to_f)
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::InvalidApiResponse")
  end

  it "defers remaining batch users and clears the batch error only after completion" do
    DiscourseCrm::SyncConfiguration.record_result(
      configuration.id,
      error: Hubspot::InvalidApiResponse.new,
    )
    throttle =
      stub_request(:get, "#{hubspot_url}/properties/contacts").to_return(
        status: 429,
        headers: {
          "Retry-After" => "30",
        },
      )
    Jobs::Hubspot::PushUserBatch.clear
    freeze_time

    Jobs::Hubspot::PushUserBatch.new.execute(
      configuration_id: configuration.id,
      user_ids: [user.id],
      reason: "backfill",
    )

    job = Jobs::Hubspot::PushUserBatch.jobs.last
    expect(job["args"].first).to include(
      "user_ids" => [user.id],
      "configuration_id" => configuration.id,
    )
    expect(job["at"]).to eq(30.seconds.from_now.to_f)
    expect(configuration.reload.last_error).to eq("Hubspot::InvalidApiResponse")
    remove_request_stub(throttle)
    stub_batch_contacts
    stub_request(:post, "#{hubspot_url}/objects/contacts/batch/create").to_return(
      body: { results: [{ id: "42", properties: { email: user.email } }] }.to_json,
    )
    freeze_time 31.seconds.from_now
    Discourse.redis.without_namespace.expire("hubspot_api:12345:6789:cooldown", 0)
    Jobs::Hubspot::PushUserBatch.new.execute(job["args"].first.symbolize_keys)
    expect(configuration.reload.last_error).to be_nil
    expect(configuration.record_link_for(user.id).external_id).to eq("42")
  end

  it "keeps single-contact API validation failures out of scheduled retries" do
    stub_contact(nil, status: 404)
    stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(
      status: 400,
      body: {
        category: "VALIDATION_ERROR",
        errors: [{ code: "INVALID_OPTION", name: "community_source" }],
      }.to_json,
    )

    expect { run_sync }.not_to raise_error

    expect(configuration.sync_states.find_by!(user_id: user.id).error).to eq(
      "Hubspot::ApiValidationError",
    )
    Jobs::Hubspot::PushUserBatch.clear
    Jobs::DiscourseCrm::SyncOutboundConfiguration.new.execute(
      configuration_id: configuration.id,
      reason: "scheduled",
    )
    expect(Jobs::Hubspot::PushUserBatch.jobs).to be_empty
  end

  it "records deterministic API validation failures without retrying users" do
    stub_batch_contacts
    create =
      stub_request(:post, "#{hubspot_url}/objects/contacts/batch/create").to_return(
        status: 207,
        body: {
          results: [],
          errors: [
            { category: "VALIDATION_ERROR", context: { objectWriteTraceId: [user.id.to_s] } },
          ],
        }.to_json,
      )
    described_class.clear
    Jobs::Hubspot::PushUserBatch.new.execute(
      configuration_id: configuration.id,
      user_ids: [user.id],
      reason: "backfill",
    )
    expect(described_class.jobs).to be_empty
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::ApiValidationError")
    Jobs::Hubspot::PushUserBatch.clear
    Jobs::DiscourseCrm::SyncOutboundConfiguration.new.execute(
      configuration_id: configuration.id,
      reason: "scheduled",
    )
    expect(Jobs::Hubspot::PushUserBatch.jobs).to be_empty
    DiscourseCrm::ConfigurationScheduler.configuration_saved(
      configuration.reload,
      group_ids_changed: false,
    )
    expect(Jobs::Hubspot::PushUserBatch.jobs.map { |job| job["args"].first["user_ids"] }).to eq(
      [[user.id]],
    )
    expect(create).to have_been_requested.once
    expect(configuration.sync_states.find_by(user_id: user.id).fingerprint).to be_nil
  end

  it "rejects invalid source options and clears the error after the source is corrected" do
    properties =
      hubspot_properties +
        [
          {
            name: "stage",
            label: "Stage",
            type: "enumeration",
            fieldType: "select",
            options: [{ value: "customer", label: "Customer" }],
          },
        ]
    stub_request(:get, "#{hubspot_url}/properties/contacts").to_return(
      body: { results: properties }.to_json,
    )
    configuration.update!(
      mappings: [{ "source" => "last", "destination" => "stage", "policy" => "overwrite" }],
    )
    stub_request(:get, "#{hubspot_url}/objects/contacts/#{ERB::Util.url_encode(user.email)}").with(
      query: {
        idProperty: "email",
        properties: "stage",
      },
    ).to_return(status: 404)
    run_sync
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::InvalidPropertyValue")
    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made

    user.update!(name: "Alex customer")
    create =
      stub_request(:post, "#{hubspot_url}/objects/contacts").with(
        body: {
          properties: {
            email: user.email,
            stage: "customer",
          },
        },
      ).to_return(body: { id: "42" }.to_json)
    run_sync
    expect(create).to have_been_requested.once
    expect(configuration.reload.sync_status["error"]).to be_nil
  end

  it "refreshes stale options once and pushes a newly allowed value" do
    field = { name: "stage", label: "Stage", type: "enumeration", fieldType: "select" }
    metadata =
      stub_request(:get, "#{hubspot_url}/properties/contacts").to_return(
        {
          body: {
            results: hubspot_properties + [field.merge(options: [{ value: "customer" }])],
          }.to_json,
        },
        {
          body: {
            results:
              hubspot_properties +
                [field.merge(options: [{ value: "customer" }, { value: "Morgan" }])],
          }.to_json,
        },
      )
    configuration.update!(
      mappings: [{ "source" => "last", "destination" => "stage", "policy" => "overwrite" }],
    )
    stub_request(:get, "#{hubspot_url}/objects/contacts/#{ERB::Util.url_encode(user.email)}").with(
      query: {
        idProperty: "email",
        properties: "stage",
      },
    ).to_return(status: 404)
    create =
      stub_request(:post, "#{hubspot_url}/objects/contacts").with(
        body: {
          properties: {
            email: user.email,
            stage: "Morgan",
          },
        },
      ).to_return(body: { id: "42" }.to_json)
    run_sync
    expect(metadata).to have_been_requested.twice
    expect(create).to have_been_requested.once
    expect(configuration.reload.sync_status["error"]).to be_nil
  end

  it "preserves checkbox append syntax while rejecting empty option segments" do
    metadata =
      stub_request(:get, "#{hubspot_url}/properties/contacts").to_return(
        body: {
          results:
            hubspot_properties +
              [
                {
                  name: "roles",
                  label: "Roles",
                  type: "enumeration",
                  fieldType: "checkbox",
                  options: [{ value: "a" }, { value: "b" }],
                },
              ],
        }.to_json,
      )
    mapping = {
      "source" => "static",
      "value" => ";a;b",
      "destination" => "roles",
      "policy" => "overwrite",
    }
    configuration.update!(mappings: [mapping])
    stub_request(:get, "#{hubspot_url}/objects/contacts/#{ERB::Util.url_encode(user.email)}").with(
      query: {
        idProperty: "email",
        properties: "roles",
      },
    ).to_return(body: { id: "42", properties: { roles: "a" } }.to_json)
    update =
      stub_request(:patch, "#{hubspot_url}/objects/contacts/42").with(
        body: {
          properties: {
            roles: ";a;b",
          },
        },
      ).to_return(body: { id: "42" }.to_json)
    run_sync
    expect(update).to have_been_requested.once
    expect(metadata).to have_been_requested.once

    configuration.update!(mappings: [mapping.merge("value" => "a;;b")])
    stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
      query: {
        properties: "roles",
      },
    ).to_return(body: { id: "42", properties: { roles: "a;b" } }.to_json)
    logs = track_log_messages { run_sync }
    expect(logs.warnings.count { |line| line.include?("HubSpot mapping rejected") }).to eq(1)
    expect(metadata).to have_been_requested.twice
    expect(update).to have_been_requested.once
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::InvalidPropertyValue")
  end

  { "unlinked" => false, "linked" => true }.each do |contact_state, linked|
    it "retries only failed #{contact_state} users on save with scheduling and backfill disabled" do
      stub_contact(nil, status: 404)
      stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(body: { id: "42" }.to_json)
      run_sync if linked
      configuration.update!(schedule: "manual", backfill: false)
      group.add(Fabricate(:verified_user))
      Hubspot::ConfiguredUserBatchSync.stubs(:sync).raises(Hubspot::InvalidCredentials)
      expect {
        Jobs::Hubspot::PushUserBatch.new.execute(
          configuration_id: configuration.id,
          user_ids: [user.id],
          reason: "change",
        )
      }.not_to raise_error
      expect(configuration.reload.last_error).to eq("Hubspot::InvalidCredentials")
      expect(configuration.sync_states.first.fingerprint).to be_present if linked
      expect(configuration.sync_states.pluck(:user_id, :error)).to eq(
        [[user.id, "Hubspot::InvalidCredentials"]],
      )
      Hubspot::ConfiguredUserBatchSync.unstub(:sync)
      Jobs::DiscourseCrm::SyncOutboundConfiguration.clear
      Jobs::Hubspot::PushUserBatch.clear

      params =
        configuration
          .attributes
          .slice(
            "name",
            "provider",
            "direction",
            "kind",
            "object",
            "schedule",
            "backfill",
            "mappings",
          )
          .merge("group_ids" => [group.id])
      DiscourseCrm::SyncConfiguration.create_or_update!(
        params,
        id: configuration.id,
        guardian: Guardian.new(Fabricate(:admin)),
      )
      expect(Jobs::DiscourseCrm::SyncOutboundConfiguration.jobs).to be_empty
      expect(configuration.reload.last_error).to eq("Hubspot::InvalidCredentials")

      batches = Jobs::Hubspot::PushUserBatch.jobs
      expect(batches.size).to eq(1)
      expect(batches.first["args"].first).to include("user_ids" => [user.id], "reason" => "retry")
      if linked
        stub_batch_contacts(
          [
            {
              id: "42",
              properties: {
                firstname: "Alex",
                lastname: "Changed externally",
                community_source: "Discourse",
              },
            },
          ],
        )
        update =
          stub_request(:post, "#{hubspot_url}/objects/contacts/batch/update").with(
            body: {
              inputs: [{ id: "42", properties: { lastname: "Morgan" } }],
            },
          ).to_return(body: { results: [{ id: "42" }] }.to_json)
      else
        stub_batch_contacts
        stub_batch_create
      end
      Jobs::Hubspot::PushUserBatch.new.execute(batches.first["args"].first.symbolize_keys)
      expect(configuration.record_link_for(user.id).external_id).to eq("42")
      expect(update).to have_been_requested.once if linked
      expect(configuration.reload.last_error).to be_nil
    end
  end

  it "clears the batch error when its users recover through individual jobs" do
    configuration.update!(schedule: "manual", backfill: false)
    Hubspot::ConfiguredUserBatchSync.stubs(:sync).raises(Hubspot::InvalidCredentials)
    expect {
      Jobs::Hubspot::PushUserBatch.new.execute(
        configuration_id: configuration.id,
        user_ids: [user.id],
        reason: "change",
      )
    }.not_to raise_error
    Hubspot::ConfiguredUserBatchSync.unstub(:sync)
    stub_contact(nil, status: 404)
    stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(body: { id: "42" }.to_json)
    run_sync("change")
    expect(configuration.record_link_for(user.id).external_id).to eq("42")
    expect(configuration.sync_states.where.not(error: nil)).to be_empty
    Jobs::Hubspot::PushUserBatch.clear
    Jobs::DiscourseCrm::SyncOutboundConfiguration.clear
    DiscourseCrm::ConfigurationScheduler.configuration_saved(
      configuration.reload,
      group_ids_changed: false,
    )
    expect(Jobs::Hubspot::PushUserBatch.jobs).to be_empty
    expect(Jobs::DiscourseCrm::SyncOutboundConfiguration.jobs).to be_empty
    expect(configuration.reload.sync_status["error"]).to be_nil
  end

  it "rejects oversized batches without syncing users or recording a configuration failure" do
    Hubspot::ConfiguredUserBatchSync.expects(:sync).never
    expect {
      Jobs::Hubspot::PushUserBatch.new.execute(
        configuration_id: configuration.id,
        user_ids: (1..101).to_a,
        reason: "retry",
      )
    }.not_to raise_error
    expect(configuration.reload.last_error).to be_nil
    expect(configuration.sync_states).to be_empty
  end

  it "keeps failed batch users visible and retries them independently" do
    stub_batch_contacts
    stub_request(:post, "#{hubspot_url}/objects/contacts/batch/create").to_return(
      status: 503,
      body: "unavailable",
    )
    described_class.clear

    Jobs::Hubspot::PushUserBatch.new.execute(
      configuration_id: configuration.id,
      user_ids: [user.id],
      reason: "backfill",
    )

    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::InvalidApiResponse")
    expect(described_class.jobs.map { |job| job["args"].first }).to include(
      hash_including("user_id" => user.id, "configuration_id" => configuration.id),
    )
  end

  { "authentication failure" => 401, "daily quota exhaustion" => 429 }.each do |failure, status|
    it "retains successful users and retries only unfinished users after #{failure}" do
      remaining = Fabricate.times(2, :verified_user)
      remaining.each { |member| group.add(member) }
      stub_batch_contacts([{ id: "42", properties: { email: user.email } }])
      stub_request(:post, "#{hubspot_url}/objects/contacts/batch/update").to_return(
        body: { results: [{ id: "42" }] }.to_json,
      )
      stub_request(:post, "#{hubspot_url}/objects/contacts/batch/create").to_return(
        status: status,
        body: { policyName: "DAILY" }.to_json,
      )
      described_class.clear
      Jobs::Hubspot::PushUserBatch.clear

      expect {
        Jobs::Hubspot::PushUserBatch.new.execute(
          configuration_id: configuration.id,
          user_ids: [user.id, *remaining.map(&:id)],
          reason: "backfill",
        )
      }.not_to raise_error

      expect(configuration.record_link_for(user.id).external_id).to eq("42")
      expect(configuration.sync_states.find_by(user_id: user.id).error).to be_nil
      expect(configuration.sync_states.where.not(error: nil).pluck(:user_id)).to match_array(
        remaining.map(&:id),
      )
      expect(described_class.jobs).to be_empty
      expect(Jobs::Hubspot::PushUserBatch.jobs).to be_empty
      DiscourseCrm::ConfigurationScheduler.configuration_saved(
        configuration.reload,
        group_ids_changed: false,
      )
      expect(Jobs::Hubspot::PushUserBatch.jobs.map { |job| job["args"].first["user_ids"] }).to eq(
        [remaining.map(&:id)],
      )
    end
  end

  it "stops the batch on an account mismatch without fanning out retries" do
    SiteSetting.hubspot_access_token = "OTHER_PORTAL_TOKEN"
    stub_request(:post, "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info").with(
      body: {
        tokenKey: "OTHER_PORTAL_TOKEN",
      },
    ).to_return(body: { hubId: 99_999, appId: 6789 }.to_json)
    described_class.clear

    expect {
      Jobs::Hubspot::PushUserBatch.new.execute(
        configuration_id: configuration.id,
        user_ids: [user.id],
        reason: "backfill",
      )
    }.not_to raise_error

    expect(described_class.jobs).to be_empty
    expect(configuration.reload.last_error).to eq("Hubspot::InvalidCredentials")
    expect(a_request(:get, %r{/crm/v3/})).not_to have_been_made
  end
end
