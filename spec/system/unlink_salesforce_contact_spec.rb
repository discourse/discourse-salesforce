# frozen_string_literal: true

RSpec.describe "Unlink Salesforce contact" do
  include ThemeScreenshotMarker

  fab!(:admin)
  fab!(:user)
  fab!(:post) { Fabricate(:post, user: user) }

  let(:topic_page) { PageObjects::Pages::SalesforceContactTopic.new }
  let(:dialog) { PageObjects::Components::Dialog.new }
  let(:contact_id) { "003INVALIDCONTACT" }

  before do
    enable_current_plugin
    SiteSetting.salesforce_enabled = true
    SiteSetting.external_system_avatars_url = "/images/avatar.png"
    SiteSetting.salesforce_case_unlink_allowed_groups = "admins"
    user.upsert_custom_fields(Salesforce::Contact::ID_FIELD => contact_id)
    sign_in(admin)
  end

  it "lets permitted staff unlink the author's Contact from the post menu" do
    topic_page.visit_topic(post.topic)
    expect(topic_page).to have_contact_for(post)
    topic_page.open_contact_menu(post)
    expect(topic_page).to have_contact_unlink_action
    screenshot_marker(label: "salesforce-contact-unlink-menu")

    topic_page.unlink_contact
    expect(dialog).to be_open
    expect(dialog).to have_content(contact_id)
    expect(dialog).to have_content("@#{user.username}")
    screenshot_marker(label: "salesforce-contact-unlink-confirmation")
    dialog.click_yes

    expect(dialog).to be_closed
    expect(topic_page).to have_no_contact_for(post)
    topic_page.open_contact_menu(post)
    expect(topic_page).to have_contact_creation_action
    screenshot_marker(label: "salesforce-contact-unlink-complete")

    page.refresh
    expect(topic_page).to have_no_contact_for(post)
  end
end
