# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "HubSpot sync configuration" do
  include_context "with hubspot spec helper"

  fab!(:admin)

  let(:configurations_page) { PageObjects::Pages::SalesforceConfigurations.new }

  before do
    stub_hubspot_properties(%w[lifecyclestage jobtitle city])
    stub_hubspot_properties(%w[name plan_tier], object: "company")
    sign_in(admin)
  end

  it "creates a HubSpot contact pull from the configurations page" do
    configurations_page.visit.start_pull

    expect(configurations_page).to have_pull_object("HubSpot - Contacts")
    expect(configurations_page).to have_selected_properties("Lifecyclestage")
    expect(configurations_page).to have_no_company_properties

    configurations_page
      .select_property("Jobtitle")
      .enable_company_pull
      .select_property("Plan tier", object: "company")
      .choose_schedule("weekly")
      .save

    expect(configurations_page).to have_configuration(
      "Pull contacts",
      type: "Pull contacts from CRM",
      scope: "All users",
    )
    expect(configurations_page).to have_pull_disabled

    page.refresh

    expect(configurations_page).to have_configuration(
      "Pull contacts",
      type: "Pull contacts from CRM",
      scope: "All users",
    )

    configurations_page.open_configuration("Pull contacts")

    expect(configurations_page).to have_selected_properties("Lifecyclestage", "Jobtitle")
    expect(configurations_page).to have_company_pull
    expect(configurations_page).to have_selected_properties("Plan tier", object: "company")
    expect(configurations_page).to have_schedule("weekly")
  end
end
