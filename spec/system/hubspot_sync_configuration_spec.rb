# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "HubSpot sync configuration" do
  include_context "with hubspot spec helper"

  fab!(:admin)

  let(:configurations_page) { PageObjects::Pages::SalesforceConfigurations.new }

  before do
    stub_hubspot_properties(%w[lifecyclestage jobtitle city])
    sign_in(admin)
  end

  it "creates a HubSpot contact pull from the configurations page" do
    configurations_page.visit.start_hubspot_pull

    expect(configurations_page).to have_selected_properties("Lifecyclestage")

    configurations_page.select_property("Jobtitle").choose_schedule("weekly").save

    expect(configurations_page).to have_configuration(
      "Pull contacts",
      type: "Pull contacts from HubSpot",
      scope: "All users",
    )
    expect(configurations_page).to have_hubspot_pull_disabled

    page.refresh

    expect(configurations_page).to have_configuration(
      "Pull contacts",
      type: "Pull contacts from HubSpot",
      scope: "All users",
    )

    configurations_page.open_configuration("Pull contacts")

    expect(configurations_page).to have_selected_properties("Lifecyclestage", "Jobtitle")
    expect(configurations_page).to have_schedule("weekly")
  end
end
