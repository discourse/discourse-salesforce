# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::SyncConfiguration do
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
    expect(described_class.for_current_account).to contain_exactly(configuration, inactive)
    SiteSetting.enable_guided_sync_configuration = false
    expect(described_class.active).to be_empty
  end

  it "rejects unsupported providers before contacting Salesforce" do
    expect {
      described_class.create_or_update!(
        { provider: "unsupported" },
        id: nil,
        guardian: Fabricate(:admin).guardian,
      )
    }.to raise_error(Discourse::InvalidParameters, /provider/)
  end

  it "removes group scopes and sync states together with the configuration" do
    DiscourseCrm::SyncState.store(configuration.id, user.id, fingerprint: "abc")

    described_class.remove!(configuration.id, guardian: Fabricate(:admin).guardian)

    expect(
      DiscourseCrm::SyncConfigurationGroup.where(configuration_id: configuration.id),
    ).to be_empty
    expect(DiscourseCrm::SyncState.where(configuration_id: configuration.id)).to be_empty
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
