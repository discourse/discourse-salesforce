# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Jobs::Hubspot::PushUserBatch do
  include_context "with hubspot spec helper"

  fab!(:group)
  fab!(:user) { Fabricate(:verified_user, name: "Alex Morgan") }
  fab!(:other_user) { Fabricate(:verified_user, name: "Maya Chen") }
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
        { "source" => "posts_read", "destination" => "community_posts", "policy" => "overwrite" },
      ],
    )
  end

  before do
    group.add(user)
    group.add(other_user)
    user.user_stat.update!(posts_read_count: 10)
    other_user.user_stat.update!(posts_read_count: 20)
    Jobs::Hubspot::PushUser.clear
    described_class.clear
  end

  def run_batch(ids = [user.id, other_user.id], reason: "backfill")
    described_class.new.execute(configuration_id: configuration.id, user_ids: ids, reason: reason)
  end

  def batch_read(records, id_property: "email", status: 200, errors: [])
    stub_request(:post, hubspot_url("objects/contacts/batch/read"))
      .with { |request| JSON.parse(request.body)["idProperty"] == id_property }
      .to_return(
        status: status,
        body: { status: "COMPLETE", results: records, errors: errors }.to_json,
      )
  end

  def link(member, id)
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      user_id: member.id,
      external_id: id,
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

  it "creates 100 contacts with one batch read and one batch write and matches unordered results" do
    members = [user, other_user, *Fabricate.times(98, :verified_user)]
    GroupUser.insert_all!(
      members.drop(2).map { |member| { group_id: group.id, user_id: member.id } },
    )
    read =
      stub_request(:post, hubspot_url("objects/contacts/batch/read"))
        .with do |request|
          JSON.parse(request.body).fetch("inputs").map { |input| input["id"] }.sort ==
            members.map(&:email).sort
        end
        .to_return(status: 404, body: { category: "OBJECT_NOT_FOUND" }.to_json)
    create =
      stub_request(:post, hubspot_url("objects/contacts/batch/create"))
        .with do |request|
          inputs = JSON.parse(request.body).fetch("inputs")
          inputs.size == 100 &&
            inputs.map { |input| input["objectWriteTraceId"] }.sort ==
              members.map { |member| member.id.to_s }.sort
        end
        .to_return(
          body: {
            status: "COMPLETE",
            results:
              members.reverse.map do |member|
                { id: "contact-#{member.id}", properties: { email: member.email } }
              end,
          }.to_json,
        )

    run_batch(members.map(&:id))

    expect(read).to have_been_requested.once
    expect(create).to have_been_requested.once
    members.each do |member|
      expect(configuration.record_link_for(member.id).external_id).to eq("contact-#{member.id}")
    end
    expect(configuration.sync_states.where.not(fingerprint: nil).count).to eq(100)
    expect(Jobs::Hubspot::PushUser.jobs).to be_empty
    expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_requested.once
  end

  it "reads by ID and email and preserves existing fields when updating secondary-email matches" do
    link(user, "one")
    batch_read(
      [{ id: "one", properties: { firstname: "Existing", lastname: "Old", community_posts: "0" } }],
      id_property: nil,
    )
    batch_read(
      [
        {
          id: "two",
          properties: {
            email: "primary@example.com",
            hs_additional_emails: other_user.email,
            firstname: "CRM",
            lastname: "Old",
            community_posts: "0",
          },
        },
      ],
    )
    update =
      stub_request(:post, hubspot_url("objects/contacts/batch/update")).with(
        body: {
          inputs: [
            { id: "one", properties: { lastname: "Morgan", community_posts: 10 } },
            { id: "two", properties: { lastname: "Chen", community_posts: 20 } },
          ],
        },
      ).to_return(body: { results: [{ id: "two" }, { id: "one" }] }.to_json)

    run_batch

    expect(update).to have_been_requested.once
    expect(configuration.record_link_for(other_user.id).external_id).to eq("two")
    expect(a_request(:post, hubspot_url("objects/contacts/batch/create"))).not_to have_been_made
    run_batch(reason: "change")
    expect(
      a_request(:post, hubspot_url("objects/contacts/batch/read")),
    ).to have_been_requested.twice
    expect(update).to have_been_requested.once
  end

  it "refreshes stale options once for the batch and validates against the new metadata" do
    configuration.update!(
      mappings: [{ "source" => "first", "destination" => "firstname", "policy" => "overwrite" }],
    )
    properties = [
      {
        name: "firstname",
        label: "First name",
        type: "enumeration",
        fieldType: "select",
        options: [{ value: "Alex" }],
      },
    ]
    metadata =
      stub_request(:get, hubspot_url("properties/contacts"))
        .to_return(body: { results: [hubspot_properties.first, *properties] }.to_json)
        .then
        .to_return(
          body: {
            results: [
              hubspot_properties.first,
              properties.first.merge(options: [{ value: "Alex" }, { value: "Maya" }]),
            ],
          }.to_json,
        )
    batch_read([])
    create =
      stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
        body: {
          results: [
            { id: "one", properties: { email: user.email } },
            { id: "two", properties: { email: other_user.email } },
          ],
        }.to_json,
      )

    run_batch

    expect(metadata).to have_been_requested.twice
    expect(create).to have_been_requested.once
    expect(configuration.sync_states.where.not(error: nil)).to be_empty
  end

  it "excludes unverified and out-of-group users from writes and batch failures" do
    other_user.email_tokens.delete_all
    other_user.email_tokens.create!(email: other_user.email, scope: EmailToken.scopes[:signup])
    outsider = Fabricate(:verified_user)
    read = batch_read([])
    create =
      stub_request(:post, hubspot_url("objects/contacts/batch/create")).with(
        body: {
          inputs: [
            {
              objectWriteTraceId: user.id.to_s,
              properties: {
                email: user.email,
                firstname: "Alex",
                lastname: "Morgan",
                community_posts: 10,
              },
            },
          ],
        },
      ).to_return(status: 401)

    run_batch([user.id, other_user.id, outsider.id])

    expect(read).to have_been_requested.once
    expect(create).to have_been_requested.once
    expect(configuration.sync_states.pluck(:user_id)).to eq([user.id])
    expect(Jobs::Hubspot::PushUser.jobs).to be_empty
  end

  it "keeps partial successes, records validation failures and retries only unresolved writes" do
    third = Fabricate(:verified_user)
    group.add(third)
    Jobs::Hubspot::PushUser.clear
    batch_read([])
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
      status: 207,
      body: {
        status: "COMPLETE",
        results: [{ id: "one", properties: { email: user.email } }],
        errors: [
          {
            category: "VALIDATION_ERROR",
            message: "Rejected sensitive-value@example.com",
            context: {
              objectWriteTraceId: [other_user.id.to_s],
              propertyName: ["firstname"],
            },
            errors: [{ code: "INVALID_OPTION", context: { propertyName: ["firstname"] } }],
          },
        ],
      }.to_json,
    )

    logs = track_log_messages { run_batch([user.id, other_user.id, third.id]) }

    expect(logs.warnings.size).to eq(1)
    expect(logs.warnings.first).to include(
      "batch_create",
      "VALIDATION_ERROR",
      "INVALID_OPTION",
      "firstname",
    )
    expect(logs.warnings.first).not_to include("sensitive-value@example.com", other_user.email)
    expect(configuration.sync_states.find_by!(user_id: other_user.id).error).to eq(
      "Hubspot::ApiValidationError",
    )
    expect(configuration.record_link_for(user.id).external_id).to eq("one")
    expect(configuration.sync_states.find_by!(user_id: user.id).error).to be_nil
    expect(configuration.sync_states.where.not(error: nil).pluck(:user_id)).to contain_exactly(
      other_user.id,
      third.id,
    )
    expect(Jobs::Hubspot::PushUser.jobs.map { |job| job["args"].first["user_id"] }).to eq(
      [third.id],
    )
  end

  it "reconciles each user when a batch lookup rejects an unspecified email" do
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      status: 400,
      body: {
        category: "VALIDATION_ERROR",
        errors: [{ code: "INVALID_EMAIL", name: "email" }],
      }.to_json,
    )

    run_batch

    expect(
      Jobs::Hubspot::PushUser.jobs.map { |job| job.fetch("args").first.fetch("user_id") },
    ).to contain_exactly(user.id, other_user.id)
    expect(configuration.sync_states.pluck(:error).uniq).to eq(["Hubspot::InvalidApiResponse"])
    expect(DiscourseCrm::SyncAttempt.pluck(:diagnostics).uniq).to eq(
      [{ "status" => 400, "codes" => ["INVALID_BATCH_READ_RESPONSE"] }],
    )
  end

  it "reconciles unaffected users when HubSpot rejects a batch email with status 422" do
    third = Fabricate(:verified_user)
    group.add(third)
    Jobs::Hubspot::PushUser.clear
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      status: 422,
      body: { code: "INVALID_EMAIL", name: "email", value: user.email }.to_json,
    )
    run_batch([user.id, other_user.id, third.id])
    expect(
      Jobs::Hubspot::PushUser.jobs.map { |job| job["args"].first["user_id"] },
    ).to contain_exactly(other_user.id, third.id)
    expect(DiscourseCrm::SyncAttempt.where(outcome: "failed").pluck(:user_id)).to contain_exactly(
      user.id,
      nil,
    )
  end

  it "keeps a shared validation reason for each explicitly identified input" do
    batch_read([])
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
      status: 207,
      body: {
        results: [],
        errors: [
          {
            category: "VALIDATION_ERROR",
            code: "INVALID_OPTION",
            context: {
              objectWriteTraceId: [user.id.to_s, other_user.id.to_s],
            },
          },
        ],
      }.to_json,
    )
    run_batch
    attempts = DiscourseCrm::SyncAttempt.where(outcome: "failed")
    expect(attempts.pluck(:user_id)).to contain_exactly(user.id, other_user.id)
    expect(attempts.pluck(:diagnostics)).to all(include("codes" => ["INVALID_OPTION"]))
    expect(Jobs::Hubspot::PushUser.jobs).to be_empty
  end

  it "retains a validation reason without a trace ID for a single write" do
    batch_read([])
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
      status: 207,
      body: {
        results: [],
        errors: [{ category: "VALIDATION_ERROR", code: "INVALID_OPTION" }],
      }.to_json,
    )
    run_batch([user.id])
    expect(DiscourseCrm::SyncAttempt.sole.diagnostics.fetch("codes")).to eq(["INVALID_OPTION"])
    expect(Jobs::Hubspot::PushUser.jobs).to be_empty
  end

  it "does not attach another user's rejected email to a conflicting trace ID" do
    batch_read([])
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
      status: 207,
      body: {
        results: [],
        errors: [
          {
            category: "VALIDATION_ERROR",
            code: "INVALID_EMAIL",
            name: "email",
            value: other_user.email,
            context: {
              objectWriteTraceId: [user.id.to_s],
            },
          },
        ],
      }.to_json,
    )
    run_batch
    expect(DiscourseCrm::SyncAttempt.pluck(:diagnostics)).to all(
      satisfy { |details| !details.key?("rejected_values") },
    )
    expect(
      Jobs::Hubspot::PushUser.jobs.map { |job| job.fetch("args").first.fetch("user_id") },
    ).to contain_exactly(user.id, other_user.id)
  end

  it "leaves contradictory create results for individual reconciliation" do
    batch_read([])
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
      body: {
        results: [
          { id: "one", objectWriteTraceId: user.id.to_s, properties: { email: other_user.email } },
        ],
      }.to_json,
    )

    run_batch

    expect(configuration.record_links).to be_empty
    expect(DiscourseCrm::SyncAttempt.pluck(:outcome)).to eq(%w[failed failed])
    expect(
      Jobs::Hubspot::PushUser.jobs.map { |job| job.fetch("args").first.fetch("user_id") },
    ).to contain_exactly(user.id, other_user.id)
  end

  it "reconciles only the user with both a write result and an attributed error" do
    batch_read([])
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
      status: 207,
      body: {
        results: [
          { id: "one", objectWriteTraceId: user.id.to_s },
          { id: "two", objectWriteTraceId: other_user.id.to_s },
        ],
        errors: [
          {
            category: "VALIDATION_ERROR",
            code: "INVALID_OPTION",
            context: {
              objectWriteTraceId: [user.id.to_s],
            },
          },
        ],
      }.to_json,
    )

    run_batch

    expect(configuration.record_links.pluck(:user_id, :external_id)).to eq([[other_user.id, "two"]])
    expect(DiscourseCrm::SyncAttempt.where(outcome: "failed").pluck(:user_id)).to eq([user.id])
    expect(DiscourseCrm::SyncAttempt.where(outcome: "success").pluck(:user_id)).to eq(
      [other_user.id],
    )
    expect(
      Jobs::Hubspot::PushUser.jobs.map { |job| job.fetch("args").first.fetch("user_id") },
    ).to eq([user.id])
  end

  it "preserves independent successes when HubSpot repeats a created contact ID" do
    third = Fabricate(:verified_user)
    group.add(third)
    Jobs::Hubspot::PushUser.clear
    batch_read([])
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
      body: {
        results: [
          { id: "shared", objectWriteTraceId: user.id.to_s },
          { id: "shared", objectWriteTraceId: other_user.id.to_s },
          { id: "third", properties: { email: third.email } },
        ],
      }.to_json,
    )

    run_batch([user.id, other_user.id, third.id])

    expect(configuration.record_links.pluck(:user_id, :external_id)).to eq([[third.id, "third"]])
    expect(DiscourseCrm::SyncAttempt.where(outcome: "success").pluck(:user_id)).to eq([third.id])
    expect(
      Jobs::Hubspot::PushUser.jobs.map { |job| job.fetch("args").first.fetch("user_id") },
    ).to contain_exactly(user.id, other_user.id)
  end

  it "summarizes a scheduled check even when another contact in the batch is rate-limited" do
    configuration.update!(schedule: "hourly")
    link(user, "one")
    link(other_user, "two")
    batch_read(
      [
        { id: "one", properties: { firstname: "Alex", lastname: "Morgan", community_posts: "10" } },
        { id: "two", properties: {} },
      ],
      id_property: nil,
    )
    stub_request(:post, hubspot_url("objects/contacts/batch/update")).to_return(status: 429)
    Jobs::DiscourseCrm::SyncOutboundConfiguration.new.execute(
      configuration_id: configuration.id,
      reason: "scheduled",
      scheduled_at: Time.current.iso8601(6),
    )
    described_class.new.execute(described_class.jobs.last["args"].first.symbolize_keys)
    expect(DiscourseCrm::SyncAttempt.order(:id).pluck(:reason)).to eq(%w[unchanged_summary failed])
    expect(DiscourseCrm::SyncAttempt.find_by!(reason: "unchanged_summary").diagnostics).to eq(
      "count" => 1,
    )
    expect(described_class.jobs.last["args"].first["user_ids"]).to eq([other_user.id])
  end

  it "records one configuration-wide failure for each rate-limited batch attempt" do
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(status: 429)
    2.times { run_batch }
    expect(DiscourseCrm::SyncAttempt.pluck(:user_id, :error_class)).to eq(
      [[nil, "Hubspot::RateLimited"], [nil, "Hubspot::RateLimited"]],
    )
  end

  it "defers only unfinished contacts when a batch write hits the rate limit" do
    batch_read([{ id: "one", properties: { email: user.email } }])
    stub_request(:post, hubspot_url("objects/contacts/batch/update")).to_return(
      body: { results: [{ id: "one" }] }.to_json,
    )
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_return(
      status: 429,
      headers: {
        "Retry-After" => "30",
      },
    )
    freeze_time

    run_batch

    expect(configuration.record_link_for(user.id).external_id).to eq("one")
    expect(configuration.sync_states.find_by!(user_id: user.id).error).to be_nil
    expect(described_class.jobs.map { |job| job["args"].first["user_ids"] }).to eq(
      [[other_user.id]],
    )
    expect(described_class.jobs.first["at"]).to eq(30.seconds.from_now.to_f)
    expect(DiscourseCrm::SyncAttempt.where(outcome: "failed").sole).to have_attributes(
      user_id: nil,
      error_class: "Hubspot::RateLimited",
    )
  end

  it "reconciles missing linked contacts individually instead of recreating them in bulk" do
    link(user, "deleted")
    batch_read([], id_property: nil, status: 207, errors: [{ category: "OBJECT_NOT_FOUND" }])
    batch_read(
      [
        {
          id: "two",
          properties: {
            email: other_user.email,
            firstname: "Maya",
            lastname: "Chen",
            community_posts: "20",
          },
        },
      ],
    )

    run_batch

    expect(configuration.record_link_for(user.id).external_id).to eq("deleted")
    expect(configuration.record_link_for(other_user.id).external_id).to eq("two")
    expect(Jobs::Hubspot::PushUser.jobs.map { |job| job["args"].first["user_id"] }).to eq([user.id])
    expect(a_request(:post, hubspot_url("objects/contacts/batch/create"))).not_to have_been_made
  end

  it "creates unmatched contacts in bulk when all read errors identify other users" do
    third = Fabricate(:verified_user)
    group.add(third)
    Jobs::Hubspot::PushUser.clear
    batch_read(
      [{ id: "one", properties: { email: user.email } }],
      status: 207,
      errors: [
        {
          category: "VALIDATION_ERROR",
          code: "INVALID_EMAIL",
          name: "email",
          value: other_user.email,
        },
      ],
    )
    stub_request(:post, hubspot_url("objects/contacts/batch/update")).to_return(
      body: { results: [{ id: "one" }] }.to_json,
    )
    stub_request(:post, hubspot_url("objects/contacts/batch/create"))
      .with do |request|
        JSON.parse(request.body).fetch("inputs").pluck("objectWriteTraceId") == [third.id.to_s]
      end
      .to_return(body: { results: [{ id: "three", properties: { email: third.email } }] }.to_json)
    run_batch([user.id, other_user.id, third.id])
    expect(configuration.record_link_for(user.id).external_id).to eq("one")
    expect(
      DiscourseCrm::SyncAttempt
        .find_by!(user_id: other_user.id)
        .diagnostics
        .fetch("rejected_values"),
    ).to eq([{ "property" => "email", "value" => other_user.email }])
    expect(configuration.record_link_for(third.id).external_id).to eq("three")
    expect(Jobs::Hubspot::PushUser.jobs).to be_empty
  end

  it "does not create contacts when HubSpot omits some batch error details" do
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      status: 207,
      body: {
        results: [],
        numErrors: 2,
        errors: [
          {
            category: "VALIDATION_ERROR",
            code: "INVALID_EMAIL",
            name: "email",
            value: other_user.email,
          },
        ],
      }.to_json,
    )
    expect { run_batch }.to raise_error(Hubspot::InvalidApiResponse)
    expect(a_request(:post, hubspot_url("objects/contacts/batch/create"))).not_to have_been_made
  end

  it "does not interpret batch read failures as missing contacts" do
    batch_read([], status: 207, errors: [{ category: "INTERNAL_ERROR" }])

    expect { run_batch }.to raise_error(Hubspot::InvalidApiResponse)

    expect(configuration.record_links).to be_empty
    expect(a_request(:post, hubspot_url("objects/contacts/batch/create"))).not_to have_been_made
  end

  it "reconciles an uncertain batch create before attempting another write" do
    batch_read([])
    stub_request(:post, hubspot_url("objects/contacts/batch/create")).to_timeout

    run_batch

    expect(DiscourseCrm::SyncAttempt.sole).to have_attributes(user_id: nil, outcome: "failed")

    expect(
      Jobs::Hubspot::PushUser.jobs.map { |job| job["args"].first["user_id"] },
    ).to contain_exactly(user.id, other_user.id)
    stub_request(:get, hubspot_url("objects/contacts/#{ERB::Util.url_encode(user.email)}")).with(
      query: {
        idProperty: "email",
        properties: "firstname,lastname,community_posts",
      },
    ).to_return(
      body: {
        id: "committed",
        properties: {
          firstname: "Alex",
          lastname: "Morgan",
          community_posts: "10",
        },
      }.to_json,
    )

    Jobs::Hubspot::PushUser.new.execute(
      configuration_id: configuration.id,
      user_id: user.id,
      reason: "backfill",
    )

    expect(configuration.record_link_for(user.id).external_id).to eq("committed")
    expect(a_request(:post, hubspot_url("objects/contacts"))).not_to have_been_made
  end
end
