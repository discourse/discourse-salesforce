# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe DiscourseWorkflows::Nodes::CrmRecords::V1, discourse_workflows: true do
  include_context "with hubspot spec helper"

  fab!(:user) { Fabricate(:user, active: true) }
  fab!(:other_user) { Fabricate(:user, active: true) }
  let!(:configuration) { Fabricate(:hubspot_sync_configuration) }

  let(:configuration_params) { { "provider" => "hubspot", "object" => "contact" } }

  def link(member, external_id)
    DiscourseCrm::RecordLink.link_many!(
      [
        {
          provider: "hubspot",
          account: "12345",
          object: "contact",
          direction: "inbound",
          user_id: member.id,
          external_id: external_id,
        },
      ],
    )
  end

  def store(object, external_id, data, company_external_id: nil, updated_at: Time.zone.now)
    DiscourseCrm::Record.store_many!(
      [
        {
          provider: "hubspot",
          account: "12345",
          object: object,
          external_id: external_id,
          company_external_id: company_external_id,
          data: data,
        },
      ],
    )
    DiscourseCrm::Record.find_by(object: object, external_id: external_id).update_columns(
      updated_at: updated_at,
    )
  end

  def run(params = configuration_params)
    output = execute_node_output(configuration: params)
    output.first.each do |item|
      expect(item["json"]).to match_node_output_schema(described_class, configuration: params)
    end
    output.first.map { |item| item["json"] }
  end

  it "lists one item per linked user with the stored contact and company properties" do
    store("company", "900", { "plan_tier" => "Enterprise", "churned_" => "No" })
    store("contact", "501", { "lifecyclestage" => "customer" }, company_external_id: "900")
    store("contact", "502", { "lifecyclestage" => "lead" })
    link(user, "501")
    link(other_user, "502")

    items = run

    expect(items.map { |item| item.dig("user", "id") }).to eq([user.id, other_user.id])
    expect(items.first).to include(
      "provider" => "hubspot",
      "object" => "contact",
      "records" => [
        {
          "external_id" => "501",
          "record" => {
            "lifecyclestage" => "customer",
          },
          "company" => {
            "plan_tier" => "Enterprise",
            "churned_" => "No",
          },
        },
      ],
    )
    expect(items.first["user"]).to include("username" => user.username)
    expect(items.last["records"]).to eq(
      [{ "external_id" => "502", "record" => { "lifecyclestage" => "lead" }, "company" => nil }],
    )
  end

  it "lists every contact of a user matched by several contacts, newest first" do
    store("contact", "501", { "lifecyclestage" => "lead" }, updated_at: 2.days.ago)
    store("contact", "503", { "lifecyclestage" => "customer" }, updated_at: 1.hour.ago)
    link(user, "501")
    link(user, "503")

    items = run

    expect(items.size).to eq(1)
    expect(items.first["records"].map { |record| record["external_id"] }).to eq(%w[503 501])
  end

  it "emits each user once however many items it receives" do
    store("contact", "501", { "lifecyclestage" => "customer" })
    link(user, "501")

    output =
      execute_node_output(
        configuration: configuration_params,
        input_items: [{ "json" => {} }, { "json" => {} }],
      )

    expect(output.first.map { |item| item.dig("json", "user", "id") }).to eq([user.id])
  end

  it "ignores outbound links and records from another portal" do
    store("contact", "501", { "lifecyclestage" => "customer" })
    DiscourseCrm::RecordLink.link!(
      provider: "hubspot",
      account: "12345",
      object: "contact",
      user_id: other_user.id,
      external_id: "501",
    )
    DiscourseCrm::Record.store_many!(
      [
        {
          provider: "hubspot",
          account: "99999",
          object: "contact",
          external_id: "777",
          company_external_id: nil,
          data: {
          },
        },
      ],
    )
    DiscourseCrm::RecordLink.link_many!(
      [
        {
          provider: "hubspot",
          account: "99999",
          object: "contact",
          direction: "inbound",
          user_id: user.id,
          external_id: "777",
        },
      ],
    )

    expect(run).to be_empty
  end

  it "rejects providers without a pull and objects the pull does not offer" do
    expect {
      execute_node_output(configuration: configuration_params.merge("provider" => "pipedrive"))
    }.to raise_error(DiscourseWorkflows::NodeError, /pipedrive/)
    expect {
      execute_node_output(configuration: configuration_params.merge("object" => "Lead"))
    }.to raise_error(DiscourseWorkflows::NodeError, /Lead/)
    expect {
      execute_node_output(configuration: configuration_params.merge("object" => "company"))
    }.to raise_error(DiscourseWorkflows::NodeError, /company/)
  end

  it "is available only while a pull configuration is active" do
    expect(described_class.available?).to eq(true)
    configuration.update!(active: false)
    expect(described_class.available?).to eq(false)
  end
end
