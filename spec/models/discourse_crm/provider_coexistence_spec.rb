# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::SyncConfiguration do
  include_context "with salesforce spec helper"
  include_context "with hubspot spec helper"

  fab!(:user, :verified_user)
  fab!(:group)

  it "dispatches both pushes and the HubSpot pull to their own jobs" do
    group.add(user)
    salesforce = Fabricate(:sync_configuration, groups: [group])
    push =
      Fabricate(
        :sync_configuration,
        provider: "hubspot",
        account: "12345",
        object: "contact",
        groups: [group],
      )
    pull = Fabricate(:hubspot_sync_configuration)
    Jobs::SyncSalesforceUser.clear
    Jobs::Hubspot::PushUser.clear
    Jobs::DiscourseCrm::PullUser.clear

    DiscourseCrm::ConfigurationScheduler.enqueue_user(user, reason: "change", inbound: true)

    expect(Jobs::SyncSalesforceUser.jobs.map { |job| job["args"].first["configuration_id"] }).to eq(
      [salesforce.id],
    )
    expect(Jobs::Hubspot::PushUser.jobs.map { |job| job["args"].first["configuration_id"] }).to eq(
      [push.id],
    )
    expect(
      Jobs::DiscourseCrm::PullUser.jobs.map { |job| job["args"].first["configuration_id"] },
    ).to eq([pull.id])
  end

  it "isolates link directions during preloading, joins and inbound contact removal" do
    push = Fabricate(:sync_configuration, provider: "hubspot", account: "12345", object: "contact")
    pull = Fabricate(:hubspot_sync_configuration)
    scope = { provider: "hubspot", account: "12345", object: "contact", user_id: user.id }
    DiscourseCrm::RecordLink.link!(**scope, external_id: "outbound")
    import = Hubspot::ContactImport.new(pull)
    import.import_page([hubspot_contact("outbound", user.email)])

    configurations = described_class.where(id: [push.id, pull.id])
    configurations
      .includes(:record_links)
      .each do |configuration|
        expect(configuration.record_links.map(&:direction)).to eq([configuration.direction])
      end
    expect(push.record_link_for(user.id).external_id).to eq("outbound")
    expect(pull.record_links.pluck(:external_id)).to eq(["outbound"])
    expect(user.crm_records.pluck(:external_id)).to eq(["outbound"])
    stub_hubspot_batch_read([])
    import.import_user(user)

    expect(configurations.joins(:record_links).pluck(:id)).to eq([push.id])
    expect(configurations.where.missing(:record_links).pluck(:id)).to eq([pull.id])
    expect(pull.record_links).to be_empty
    expect(push.record_link_for(user.id).external_id).to eq("outbound")
    expect(DiscourseCrm::Record.where(external_id: "outbound")).to be_empty
  end
end
