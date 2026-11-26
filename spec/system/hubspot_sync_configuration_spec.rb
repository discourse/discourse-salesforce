# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "HubSpot sync configuration" do
  include_context "with hubspot spec helper"

  fab!(:admin)

  let(:configurations_page) { PageObjects::Pages::SalesforceConfigurations.new }

  before do
    stub_hubspot_properties(%w[firstname lastname website lifecyclestage jobtitle city])
    stub_hubspot_properties(%w[name domain plan_tier], object: "company")
    sign_in(admin)
  end

  it "creates HubSpot contact and company pulls from the configurations page" do
    title = Fabricate(:user_field, name: "Job title", field_type: "text")
    configurations_page.visit.start_pull

    expect(configurations_page).to have_pull_object("HubSpot - Contacts")
    expect(configurations_page).to have_property("firstname+lastname", destination: "Name")
    expect(configurations_page).to have_property("website", destination: "Website")

    configurations_page
      .add_property("jobtitle")
      .choose_destination("jobtitle", "user_field_#{title.id}")
      .choose_schedule("weekly")
      .save

    expect(configurations_page).to have_configuration(
      "Pull HubSpot contacts",
      type: "Pull users from CRM",
      scope: "All users",
    )

    configurations_page.start_pull

    expect(configurations_page).to have_pull_object("HubSpot - Companies")
    expect(configurations_page).to have_property("name")
    expect(configurations_page).to have_property("domain")

    configurations_page.add_property("plan_tier").save

    expect(configurations_page).to have_configuration(
      "Pull HubSpot companies",
      type: "Pull companies from CRM",
      scope: "Companies of pulled contacts",
    )
    expect(configurations_page).to have_pull_disabled
    expect(DiscourseCrm::SyncConfiguration.find_by(object: "company")).to have_attributes(
      kind: "companies",
      mappings: [
        { "id" => 1, "object" => "company", "source" => "name" },
        { "id" => 2, "object" => "company", "source" => "domain" },
        { "id" => 3, "object" => "company", "source" => "plan_tier" },
      ],
    )

    page.refresh
    configurations_page.open_configuration("Pull HubSpot contacts")

    expect(configurations_page).to have_property("firstname+lastname", destination: "Name")
    expect(configurations_page).to have_property("jobtitle", destination: "Job title")
    expect(configurations_page).to have_schedule("weekly")
  end

  it "shows a sync loop next to the pull row that closes it" do
    Fabricate(
      :sync_configuration,
      provider: "hubspot",
      account: "12345",
      object: "contact",
      name: "Push websites",
      mappings: [{ "source" => "website", "destination" => "website", "policy" => "overwrite" }],
    )

    configurations_page.visit.start_pull.choose_policy("website", "overwrite").save

    expect(configurations_page).to have_mapping_error(
      1,
      "HubSpot contact.website → Discourse Website → HubSpot contact.website",
    )
    expect(DiscourseCrm::SyncConfiguration.inbound).to be_empty
  end
end
