# frozen_string_literal: true

RSpec.describe "Configure case and contact unlink groups" do
  include ThemeScreenshotMarker

  fab!(:admin)

  let(:settings_page) { PageObjects::Pages::SalesforceSettings.new }

  before do
    enable_current_plugin
    SiteSetting.external_system_avatars_url = "/images/avatar.png"
    sign_in(admin)
  end

  it "lets admins independently select staff roles and keeps their selections after refresh" do
    settings_page.visit("unlink_allowed_groups")
    case_groups = settings_page.unlink_groups(:case)
    case_groups.expand

    expect(settings_page).to have_two_unlink_group_options(:case)
    expect(case_groups).to have_option_name("Admins")
    expect(case_groups).to have_option_name("Moderators")

    case_groups.select_row_by_value("admins")
    case_groups.select_row_by_value("moderators")
    case_groups.collapse
    settings_page.save_setting("salesforce_case_unlink_allowed_groups")
    expect(settings_page).to have_overridden_setting("salesforce_case_unlink_allowed_groups")

    page.refresh
    expect(settings_page.find_setting("salesforce_case_unlink_allowed_groups")).to have_content(
      "Admins, Moderators",
    )
    expect(settings_page.unlink_groups(:contact)).to have_no_selection

    contact_groups = settings_page.unlink_groups(:contact)
    contact_groups.expand
    expect(settings_page).to have_two_unlink_group_options(:contact)
    expect(contact_groups).to have_option_name("Admins")
    expect(contact_groups).to have_option_name("Moderators")
    contact_groups.select_row_by_value("moderators")
    contact_groups.collapse
    settings_page.save_setting("salesforce_contact_unlink_allowed_groups")
    expect(settings_page).to have_overridden_setting("salesforce_contact_unlink_allowed_groups")

    page.refresh
    expect(settings_page.find_setting("salesforce_case_unlink_allowed_groups")).to have_content(
      "Admins, Moderators",
    )
    expect(settings_page.find_setting("salesforce_contact_unlink_allowed_groups")).to have_content(
      "Moderators",
    )

    expect(
      settings_page.find_setting("salesforce_contact_unlink_allowed_groups"),
    ).to have_no_content("Admins")

    settings_page.unlink_groups(:contact).expand
    screenshot_marker(label: "salesforce-contact-unlink-permissions")
  end
end
