# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::SyncSalesforceUser do
  include_context "with hubspot spec helper"

  fab!(:user) { Fabricate(:verified_user, name: "Alex Morgan") }
  fab!(:group)

  let!(:configuration) do
    Fabricate(
      :sync_configuration,
      provider: "hubspot",
      account: "12345",
      object: "Contact",
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

  it "retains a missing linked contact and records the failure instead of creating a duplicate" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "Contact",
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
    ).to_return(status: 404, body: "missing")

    expect { run_sync }.to raise_error(Hubspot::InvalidApiResponse)

    expect(configuration.record_link_for(user.id).external_id).to eq("42")
    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::InvalidApiResponse")
    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
  end

  it "recreates a confirmed archived contact and invalidates related fingerprints" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "Contact",
      user_id: user.id,
      external_id: "42",
    )
    related =
      Fabricate(
        :sync_configuration,
        provider: "hubspot",
        account: "12345",
        object: "Contact",
        active: false,
      )
    other_account =
      Fabricate(:sync_configuration, provider: "hubspot", account: "67890", object: "Contact")
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
      object: "Contact",
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
      object: "Contact",
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

      expect { run_sync }.to raise_error(Hubspot::InvalidApiResponse)
      expect(configuration.record_link_for(user.id).external_id).to eq("42")
    end

    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
  end

  it "retains linked contacts on permission and server errors" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "Contact",
      user_id: user.id,
      external_id: "42",
    )
    [403, 503].each do |status|
      stub_request(:get, "#{hubspot_url}/objects/contacts/42").with(
        query: {
          properties: "firstname,lastname,community_source",
        },
      ).to_return(status: status, body: "lookup failed")

      expect { run_sync }.to raise_error(Hubspot::InvalidApiResponse)
      expect(configuration.record_link_for(user.id).external_id).to eq("42")
    end

    expect(a_request(:post, "#{hubspot_url}/objects/contacts")).not_to have_been_made
    expect(
      a_request(:get, "#{hubspot_url}/objects/contacts/42").with(query: { archived: true }),
    ).not_to have_been_made
  end

  it "queues HubSpot backfills and scheduled refreshes through the shared scheduler" do
    DiscourseCrm::ConfigurationScheduler.enqueue_user(user, reason: "change")
    expect(described_class.jobs.map { |job| job["args"].first }).to include(
      hash_including("configuration_id" => configuration.id, "user_id" => user.id),
    )
    Jobs::SyncSalesforceConfiguration.new.execute(
      configuration_id: configuration.id,
      reason: "backfill",
    )
    batch = Jobs::SyncSalesforceUserBatch.jobs.last["args"].first
    described_class.clear
    stub_contact(nil, status: 404)
    created =
      stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(body: { id: "42" }.to_json)
    Jobs::SyncSalesforceUserBatch.new.execute(batch.symbolize_keys)
    expect(created).to have_been_requested.once
    expect(described_class.jobs).to be_empty
    freeze_time Time.utc(2026, 11, 10, 3)
    DiscourseCrm::ConfigurationScheduler.enqueue_due
    expect(Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first }).to include(
      hash_including("configuration_id" => configuration.id, "reason" => "scheduled"),
    )
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
  it "blocks stored links when only the token changes to another portal" do
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "Contact",
      user_id: user.id,
      external_id: "42",
    )
    SiteSetting.hubspot_access_token = "OTHER_PORTAL_TOKEN"
    stub_request(:post, "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info").with(
      body: {
        tokenKey: "OTHER_PORTAL_TOKEN",
      },
    ).to_return(body: { hubId: 99_999, appId: 6789 }.to_json)

    expect { run_sync }.to raise_error(Hubspot::InvalidCredentials)
    expect(a_request(:get, %r{/crm/v3/})).not_to have_been_made
    expect(configuration.record_link_for(user.id).external_id).to eq("42")
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
    Jobs::SyncSalesforceUserBatch.clear
    freeze_time

    Jobs::SyncSalesforceUserBatch.new.execute(
      configuration_id: configuration.id,
      user_ids: [user.id],
      reason: "backfill",
    )

    job = Jobs::SyncSalesforceUserBatch.jobs.last
    expect(job["args"].first).to include(
      "user_ids" => [user.id],
      "configuration_id" => configuration.id,
    )
    expect(job["at"]).to eq(30.seconds.from_now.to_f)
    expect(configuration.reload.last_error).to eq("Hubspot::InvalidApiResponse")
    remove_request_stub(throttle)
    stub_contact(nil, status: 404)
    stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(body: { id: "42" }.to_json)
    freeze_time 31.seconds.from_now
    Discourse.redis.without_namespace.expire("hubspot_api:12345:6789:cooldown", 0)
    Jobs::SyncSalesforceUserBatch.new.execute(job["args"].first.symbolize_keys)
    expect(configuration.reload.last_error).to be_nil
    expect(configuration.record_link_for(user.id).external_id).to eq("42")
  end

  it "keeps failed batch users visible and retries them independently" do
    stub_contact(nil, status: 404)
    stub_request(:post, "#{hubspot_url}/objects/contacts").to_return(
      status: 503,
      body: "unavailable",
    )
    described_class.clear

    Jobs::SyncSalesforceUserBatch.new.execute(
      configuration_id: configuration.id,
      user_ids: [user.id],
      reason: "backfill",
    )

    expect(configuration.reload.sync_status["error"]).to eq("Hubspot::InvalidApiResponse")
    expect(described_class.jobs.map { |job| job["args"].first }).to include(
      hash_including("user_id" => user.id, "configuration_id" => configuration.id),
    )
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
      Jobs::SyncSalesforceUserBatch.new.execute(
        configuration_id: configuration.id,
        user_ids: [user.id],
        reason: "backfill",
      )
    }.to raise_error(Hubspot::InvalidCredentials)

    expect(described_class.jobs).to be_empty
    expect(configuration.reload.last_error).to eq("Hubspot::InvalidCredentials")
    expect(a_request(:get, %r{/crm/v3/})).not_to have_been_made
  end
end
