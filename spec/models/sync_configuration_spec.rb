# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::SyncConfiguration do
  fab!(:group)
  fab!(:user) { Fabricate(:user, active: true) }
  fab!(:other_user) { Fabricate(:user, active: true) }

  before do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
    SiteSetting.salesforce_instance_url = "https://current.salesforce.com"
  end

  let!(:configuration) { Fabricate(:sync_configuration, groups: [group]) }

  it "selects only active current-account configurations" do
    stale =
      Fabricate(:sync_configuration, account: "https://previous.salesforce.com", groups: [group])
    inactive = Fabricate(:sync_configuration, active: false, groups: [group])

    expect(described_class.active).to eq([configuration])
    expect(stale.connection_changed?).to eq(true)
    expect(configuration.connection_changed?).to eq(false)
    expect(described_class.for_provider("salesforce")).to contain_exactly(configuration, inactive)
    SiteSetting.enable_guided_sync_configuration = false
    expect(described_class.active).to be_empty
  end

  it "rejects unsupported providers before contacting Salesforce" do
    expect {
      described_class.create_or_update!(
        { provider: "pipedrive" },
        id: nil,
        guardian: Fabricate(:admin).guardian,
      )
    }.to raise_error(Discourse::InvalidParameters, /provider/)
  end

  it "requires provider, direction and kind and keeps them fixed after creation" do
    admin = Fabricate(:admin)
    params = {
      provider: "salesforce",
      direction: "outbound",
      kind: "users",
      object: "Lead",
      name: "Lead sync",
      schedule: "daily",
      group_ids: [group.id],
      mappings: [],
    }

    %i[direction kind].each do |attribute|
      expect {
        described_class.create_or_update!(
          params.except(attribute),
          id: nil,
          guardian: admin.guardian,
        )
      }.to raise_error(Discourse::InvalidParameters, /#{attribute}/)
    end

    %w[provider direction kind object].each do |attribute|
      expect {
        described_class.create_or_update!(
          {
            "provider" => "salesforce",
            "direction" => "outbound",
            "kind" => "users",
            "object" => "Lead",
            "group_ids" => [group.id],
          }.merge(attribute => "other"),
          id: configuration.id,
          guardian: admin.guardian,
        )
      }.to raise_error(Discourse::InvalidParameters, /#{attribute}/)
    end
    expect(configuration.reload.slice(:provider, :direction, :kind, :object)).to eq(
      "provider" => "salesforce",
      "direction" => "outbound",
      "kind" => "users",
      "object" => "Lead",
    )
  end

  it "validates direction, kind and object against the provider" do
    expect(Fabricate.build(:sync_configuration, direction: "inbound")).to be_invalid
    expect(Fabricate.build(:sync_configuration, direction: "sideways")).to be_invalid
    expect(Fabricate.build(:sync_configuration, kind: "posts")).to be_invalid
    expect(Fabricate.build(:hubspot_sync_configuration, direction: "outbound")).to be_invalid
    expect(Fabricate.build(:hubspot_sync_configuration, object: "Lead")).to be_invalid
    expect(Fabricate.build(:hubspot_sync_configuration)).to be_valid
  end

  context "with hubspot configurations" do
    include_context "with hubspot spec helper"

    it "activates hubspot rows only when the provider is enabled for the current portal" do
      hubspot = Fabricate(:hubspot_sync_configuration)
      stale = Fabricate(:hubspot_sync_configuration, account: "99999")

      expect(described_class.active).to contain_exactly(configuration, hubspot)
      expect(stale.connection_changed?).to eq(true)
      expect(hubspot.connection_changed?).to eq(false)

      SiteSetting.hubspot_enabled = false
      expect(described_class.active).to eq([configuration])
      SiteSetting.hubspot_enabled = true
      SiteSetting.salesforce_enabled = false
      expect(described_class.active).to be_empty
    end

    it "allows a single inbound configuration per portal, enforced by the database too" do
      Fabricate(:hubspot_sync_configuration)

      expect(Fabricate.build(:hubspot_sync_configuration)).to be_invalid
      expect(Fabricate.build(:hubspot_sync_configuration, account: "99999")).to be_valid
      expect { Fabricate.build(:hubspot_sync_configuration).save!(validate: false) }.to raise_error(
        ActiveRecord::RecordNotUnique,
      )
    end

    it "rejects hubspot configurations while the provider is disabled or given groups" do
      stub_hubspot_properties(%w[lifecyclestage])
      admin = Fabricate(:admin)
      params = {
        provider: "hubspot",
        direction: "inbound",
        kind: "users",
        object: "contact",
        name: "Import contacts",
        schedule: "daily",
        mappings: [{ id: 1, source: "lifecyclestage" }],
      }

      expect {
        described_class.create_or_update!(
          params.merge(group_ids: [group.id]),
          id: nil,
          guardian: admin.guardian,
        )
      }.to raise_error(Discourse::InvalidParameters, /group_ids/)
      SiteSetting.hubspot_enabled = false
      expect {
        described_class.create_or_update!(params, id: nil, guardian: admin.guardian)
      }.to raise_error(Discourse::InvalidParameters, /provider/)
      expect(described_class.where(provider: "hubspot")).to be_empty
    end

    it "creates a hubspot configuration without groups after checking the selected properties" do
      stub_hubspot_properties(%w[lifecyclestage jobtitle])
      admin = Fabricate(:admin)
      params = {
        provider: "hubspot",
        direction: "inbound",
        kind: "users",
        object: "contact",
        name: "Import contacts",
        schedule: "weekly",
        backfill: true,
        mappings: [{ id: 1, source: "lifecyclestage" }, { id: 2, source: "jobtitle" }],
      }
      Jobs::SyncHubspotConfiguration.clear

      record = described_class.create_or_update!(params, id: nil, guardian: admin.guardian)

      expect(record.slice(:provider, :direction, :account, :kind, :object)).to eq(
        "provider" => "hubspot",
        "direction" => "inbound",
        "account" => "12345",
        "kind" => "users",
        "object" => "contact",
      )
      expect(record.groups).to be_empty
      expect(
        Jobs::SyncHubspotConfiguration.jobs.map { |job| job["args"].first },
      ).to contain_exactly(hash_including("configuration_id" => record.id, "reason" => "backfill"))

      [
        [{ id: 1, source: "missing_property" }],
        [{ id: 1, source: "jobtitle" }, { id: 2, source: "jobtitle" }],
        [{ id: 1, destination: "jobtitle" }],
      ].each do |mappings|
        expect {
          described_class.create_or_update!(
            params.merge(mappings: mappings),
            id: record.id,
            guardian: admin.guardian,
          )
        }.to raise_error(Discourse::InvalidParameters, /mappings/)
      end
      expect {
        described_class.create_or_update!(
          params.merge(name: "Second import"),
          id: nil,
          guardian: admin.guardian,
        )
      }.to raise_error(Discourse::InvalidParameters, /configuration/)
    end

    it "keeps links and records when the configuration is removed" do
      hubspot = Fabricate(:hubspot_sync_configuration)
      Salesforce::RecordLink.link_many!(
        [
          {
            provider: "hubspot",
            account: "12345",
            object: "contact",
            user_id: user.id,
            external_id: "501",
          },
        ],
      )
      record = Fabricate(:crm_record, external_id: "501")

      described_class.remove!(hubspot.id, guardian: Fabricate(:admin).guardian)

      expect(Salesforce::RecordLink.where(user_id: user.id).pluck(:external_id)).to eq(["501"])
      expect(Salesforce::Record.where(id: record.id)).to exist
    end
  end

  it "removes group scopes and sync states together with the configuration" do
    Salesforce::SyncState.store(configuration.id, user.id, fingerprint: "abc")

    described_class.remove!(configuration.id, guardian: Fabricate(:admin).guardian)

    expect(Salesforce::SyncConfigurationGroup.where(configuration_id: configuration.id)).to be_empty
    expect(Salesforce::SyncState.where(configuration_id: configuration.id)).to be_empty
    expect {
      described_class.remove!(configuration.id, guardian: Fabricate(:admin).guardian)
    }.to raise_error(Discourse::NotFound)
  end

  it "keeps unresolved user errors when another user syncs successfully" do
    group.add(user)
    group.add(other_user)

    described_class.record_result(
      configuration.id,
      user.id,
      error: Salesforce::InvalidApiResponse.new,
    )
    described_class.record_result(configuration.id, other_user.id)

    expect(configuration.reload.sync_status["error"]).to eq("Salesforce::InvalidApiResponse")
    expect(configuration.sync_states.where.not(error: nil).pluck(:user_id)).to eq([user.id])
    expect(configuration.last_synced_at).to be_present
  end

  it "hides user errors once they are no longer eligible members" do
    group.add(user)
    described_class.record_result(
      configuration.id,
      user.id,
      error: Salesforce::InvalidApiResponse.new,
    )

    group.remove(user)

    expect(configuration.reload.sync_status).not_to have_key("error")
  end

  it "reads status without writing" do
    described_class.record_result(configuration.id, user.id)

    queries = track_sql_queries { configuration.reload.sync_status }

    expect(queries.grep(/(?:INSERT INTO|UPDATE|DELETE FROM)/i)).to be_empty

    group.add(user)
    described_class.record_result(
      configuration.id,
      user.id,
      error: Salesforce::InvalidApiResponse.new,
    )
    status = nil
    queries = track_sql_queries { status = configuration.reload.sync_status }

    expect(status["error"]).to eq("Salesforce::InvalidApiResponse")
    expect(status["last_error_at"]).to be_present
    expect(queries.grep(/(?:INSERT INTO|UPDATE|DELETE FROM)/i)).to be_empty
  end

  it "stores batch errors separately from user errors and clears them on batch success" do
    described_class.record_result(configuration.id, error: Salesforce::InvalidApiResponse.new)

    expect(configuration.reload.last_error).to eq("Salesforce::InvalidApiResponse")
    expect(configuration.sync_status["error"]).to eq("Salesforce::InvalidApiResponse")

    described_class.record_batch_success(configuration.id)

    expect(configuration.reload.sync_status).not_to have_key("error")
  end
end
