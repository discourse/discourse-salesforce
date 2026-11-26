# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Define CRM segments" do
  include_context "with hubspot spec helper"

  fab!(:admin)
  fab!(:group) { Fabricate(:group, name: "enterprise-customers") }
  fab!(:enterprise_user) { Fabricate(:verified_user, username: "ada") }
  fab!(:business_user) { Fabricate(:verified_user, username: "grace") }

  let(:segments_page) { PageObjects::Pages::CrmSegments.new }
  let(:group_members_page) { PageObjects::Pages::GroupMembers.new }

  let!(:configuration) do
    Fabricate(
      :hubspot_sync_configuration,
      mappings: [
        { "id" => 1, "object" => "contact", "source" => "jobtitle" },
        { "id" => 2, "object" => "company", "source" => "plan_tier" },
      ],
    )
  end

  before do
    stub_hubspot_properties(%w[jobtitle])
    stub_hubspot_properties(%w[plan_tier], object: "company")
    SiteSetting.crm_segments_enabled = true
    Fabricate(
      :crm_record,
      object: "company",
      external_id: "acme",
      data: {
        "plan_tier" => "Enterprise",
      },
    )
    Fabricate(
      :crm_record,
      object: "company",
      external_id: "initech",
      data: {
        "plan_tier" => "Business",
      },
    )
    {
      enterprise_user => "acme",
      business_user => "initech",
    }.each_with_index do |(user, company), index|
      Fabricate(
        :crm_record,
        external_id: "50#{index}",
        company_external_id: company,
        data: {
          "jobtitle" => "CTO",
        },
      )
      DiscourseCrm::RecordLink.link_many!(
        [
          {
            provider: "hubspot",
            account: "12345",
            object: "contact",
            direction: "inbound",
            user_id: user.id,
            external_id: "50#{index}",
          },
        ],
      )
    end
    sign_in(admin)
  end

  it "lets an admin define a segment, see who it matches and keep a group in sync with it" do
    segments_page.visit.define_segment

    expect(segments_page).to have_configuration(configuration)

    segments_page
      .choose_match("any")
      .choose_property(0, "company.plan_tier")
      .choose_operator(0, "contains")
      .fill_value(0, "enterprise")
    expect(segments_page).to have_preview("Matches 1 of 2 users with CRM data")
    expect(segments_page).to have_preview("ada")

    segments_page.choose_group(group).enable_removal.save

    expect(segments_page).to have_segment("New segment", group: group, status: "pending")

    page.refresh

    expect(segments_page).to have_segment(
      "New segment",
      configuration: configuration,
      group: group,
      status: "pending",
    )

    Jobs::DiscourseCrm::EvaluateSegments.new.execute(configuration_id: configuration.id)
    page.refresh

    expect(segments_page).to have_segment("New segment", group: group, status: "synced")
    expect(segments_page).to have_member_count("New segment", 1)

    segments_page.open_segment("New segment")

    expect(segments_page).to have_configuration(configuration)
    expect(segments_page).to have_condition_value(0, "enterprise")
    expect(segments_page).to have_match("any")
    expect(segments_page).to have_group(group)
    expect(segments_page).to have_removal_enabled

    group_members_page.visit(group)

    expect(group_members_page).to have_member(enterprise_user)
    expect(group_members_page).to have_no_member(business_user)
  end

  it "lets an admin delete a segment from the list" do
    Fabricate(:crm_segment, configuration:, name: "Churn risk", group_id: group.id)

    segments_page.visit
    expect(segments_page).to have_segment("Churn risk", group: group)

    segments_page.delete_segment("Churn risk")

    expect(segments_page).to have_no_segment("Churn risk")
  end
end
