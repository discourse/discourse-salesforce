# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "salesforce:prune_dead_associations" do
  include_context "with salesforce spec helper"

  fab!(:user)
  fab!(:leads_group, :group)

  let(:contact_id) { "003000000000001" }
  let(:lead_id) { "00Q000000000001" }
  let(:case_id) { "500000000000001" }
  let!(:salesforce_case) { Fabricate(:salesforce_case, uid: case_id) }

  before do
    SiteSetting.salesforce_leads_enabled = false
    SiteSetting.salesforce_leads_group_id = leads_group.id
    user.upsert_custom_fields(
      Salesforce::Contact::ID_FIELD => contact_id,
      Salesforce::Lead::ID_FIELD => lead_id,
    )
    stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
      query: {
        fields: "Id",
        ids: contact_id,
      },
    ).to_return(status: 200, body: [nil].to_json)
    stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Case").with(
      query: {
        fields: "Id",
        ids: case_id,
      },
    ).to_return(status: 200, body: [nil].to_json)
    stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Lead").to_return(
      status: 400,
      body: %([{"errorCode":"INVALID_TYPE","message":"Lead is unavailable"}]),
    )
  end

  it "cleans Contacts and Cases while retaining disabled Lead links" do
    output =
      stub_const(Object, :ENV, ENV.to_h.merge("DRY_RUN" => nil)) do
        capture_stdout { invoke_rake_task("salesforce:prune_dead_associations") }
      end

    expect(output).to include(
      "Pruned 1 user links, 0 post references, 1 case links, and 0 settings.",
    )
    expect(user.reload.salesforce_contact_id).to be_nil
    expect(user.salesforce_lead_id).to eq(lead_id)
    expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(false)
    expect(
      a_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Lead"),
    ).not_to have_been_made
  end

  it "reports guided-only links in a dry run and removes the same links during cleanup" do
    user.user_custom_fields.where(name: Salesforce::Contact::ID_FIELD).delete_all
    salesforce_case.destroy!
    scope = { provider: "salesforce", account: instance_url, object: "Contact", user_id: user.id }
    Salesforce::RecordLink.link!(**scope, external_id: contact_id)
    configuration = Fabricate(:guided_sync_configuration, object: "Contact", account: instance_url)
    Salesforce::SyncState.store(configuration.id, user.id, fingerprint: "previous")
    fingerprint = -> do
      Salesforce::SyncState.find_by(configuration: configuration, user_id: user.id).fingerprint
    end

    dry_run_output =
      stub_const(Object, :ENV, ENV.to_h.merge("DRY_RUN" => "1")) do
        capture_stdout { invoke_rake_task("salesforce:prune_dead_associations") }
      end

    expect(dry_run_output).to include("dead contact #{contact_id}", "Dry run: nothing removed.")
    expect(dry_run_output).not_to include("No dead links found.")
    expect(Salesforce::RecordLink.find_by(**scope).external_id).to eq(contact_id)
    expect(fingerprint.call).to eq("previous")

    output =
      stub_const(Object, :ENV, ENV.to_h.merge("DRY_RUN" => nil)) do
        capture_stdout { invoke_rake_task("salesforce:prune_dead_associations") }
      end

    expect(output).to include("dead contact #{contact_id}", "Pruned 1 user links")
    expect(Salesforce::RecordLink.find_by(**scope)).to be_nil
    expect(fingerprint.call).to be_nil
  end

  it "reports Contacts and Cases without querying disabled Leads in a dry run" do
    output =
      stub_const(Object, :ENV, ENV.to_h.merge("DRY_RUN" => "1")) do
        capture_stdout { invoke_rake_task("salesforce:prune_dead_associations") }
      end

    expect(output).to include(
      "dead contact #{contact_id}",
      "dead case #{case_id}",
      "Dry run: nothing removed.",
    )
    expect(user.reload.salesforce_contact_id).to eq(contact_id)
    expect(user.salesforce_lead_id).to eq(lead_id)
    expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
    expect(
      a_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Lead"),
    ).not_to have_been_made
  end
end
