# frozen_string_literal: true

RSpec.describe "Configure case unlink groups" do
  fab!(:admin)

  let(:settings_page) { PageObjects::Pages::SalesforceSettings.new }

  before do
    enable_current_plugin
    sign_in(admin)
  end

  it "lets admins select only admins and moderators and keeps their selections after refresh" do
    settings_page.visit("salesforce_case_unlink_allowed_groups")
    groups = settings_page.unlink_groups
    groups.expand

    expect(settings_page).to have_two_unlink_group_options
    expect(groups).to have_option_name("Admins")
    expect(groups).to have_option_name("Moderators")

    groups.select_row_by_value("admins")
    groups.select_row_by_value("moderators")
    groups.collapse
    settings_page.save_setting("salesforce_case_unlink_allowed_groups")
    expect(settings_page).to have_overridden_setting("salesforce_case_unlink_allowed_groups")

    page.refresh

    expect(settings_page.find_setting("salesforce_case_unlink_allowed_groups")).to have_content(
      "Admins, Moderators",
    )
  end
end
