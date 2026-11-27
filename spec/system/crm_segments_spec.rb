# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Define CRM segments" do
  include_context "with hubspot spec helper"

  fab!(:admin)
  fab!(:group) { Fabricate(:group, name: "enterprise-customers") }
  fab!(:enterprise_user) { Fabricate(:verified_user, username: "ada") }
  fab!(:business_user) { Fabricate(:verified_user, username: "grace") }
  fab!(:enterprise_post) { Fabricate(:post, user: enterprise_user) }

  let(:segments_page) { PageObjects::Pages::CrmSegments.new }
  let(:group_members_page) { PageObjects::Pages::GroupMembers.new }
  let(:topic_page) { PageObjects::Pages::Topic.new }
  let(:flair) { PageObjects::Components::CrmFlair.new(enterprise_post) }
  let(:admins) { Group.find(Group::AUTO_GROUPS[:admins]) }

  let!(:configuration) do
    Fabricate(
      :hubspot_sync_configuration,
      mappings: [
        { "id" => 1, "object" => "contact", "source" => "jobtitle" },
        { "id" => 2, "object" => "company", "source" => "plan_tier" },
      ],
      property_metadata: {
        "contact" => {
          "jobtitle" => {
            "label" => "Job title",
            "options" => {
            },
          },
        },
        "company" => {
          "plan_tier" => {
            "label" => "Plan tier",
            "options" => {
            },
          },
        },
      },
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

  it "lets an admin define a segment, see who it matches, keep a group in sync with it and flair its members" do
    segments_page.visit.define_segment

    expect(segments_page).to have_configuration(configuration)

    segments_page
      .choose_match("any")
      .choose_property(0, "company.plan_tier")
      .choose_operator(0, "contains")
      .fill_value(0, "enterprise")
    expect(segments_page).to have_preview("Matches 1 of 2 users with CRM data")
    expect(segments_page).to have_preview("ada")

    segments_page.choose_group(group).enable_removal
    segments_page
      .enable_flair
      .choose_flair_text("company.plan_tier")
      .choose_flair_property("Job title")
      .choose_flair_group(admins)
    expect(segments_page).to have_flair_preview("Plan tier")

    segments_page.save

    expect(segments_page).to have_segment(
      "New segment",
      group: group,
      status: "pending",
      flair: "admins",
    )

    page.refresh

    expect(segments_page).to have_segment(
      "New segment",
      configuration: configuration,
      group: group,
      status: "pending",
      flair: "admins",
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
    expect(segments_page).to have_flair_enabled
    expect(segments_page).to have_flair_text("company.plan_tier")
    expect(segments_page).to have_flair_group(admins)

    group_members_page.visit(group)

    expect(group_members_page).to have_member(enterprise_user)
    expect(group_members_page).to have_no_member(business_user)

    topic_page.visit_topic(enterprise_post.topic)

    expect(flair).to have_text("Enterprise")

    flair.hover

    expect(flair).to have_property("Job title", "CTO")
    expect(flair).to have_crm_link(
      "Open in HubSpot",
      "https://app.hubspot.com/contacts/12345/record/0-1/500",
    )

    sign_in(business_user)
    topic_page.visit_topic(enterprise_post.topic)

    expect(topic_page).to have_post_number(enterprise_post.post_number)
    expect(flair).to have_no_flair
  end

  it "lets an admin delete a segment from the list" do
    Fabricate(:crm_segment, configuration:, name: "Churn risk", group_id: group.id)

    segments_page.visit
    expect(segments_page).to have_segment("Churn risk", group: group)

    segments_page.delete_segment("Churn risk")

    expect(segments_page).to have_no_segment("Churn risk")
  end
end
