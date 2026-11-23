# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "CRM sync activity" do
  fab!(:admin)
  fab!(:user)
  fab!(:configuration, :sync_configuration)

  it "fits the filters, attempts, and expanded details within a phone viewport" do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
    DiscourseCrm::SyncAttempt.record(configuration, user.id, error: StandardError.new)
    sign_in(admin)

    page.current_window.resize_to(375, 812)
    visit "/admin/plugins/discourse-salesforce/activity"
    expect(page).to have_link(user.username)
    find(".crm-sync-activity__info").click
    expect(page).to have_css(".crm-sync-activity__details", text: configuration.name)

    %w[filters table].each do |part|
      element = find(".crm-sync-activity__#{part}")
      expect(element.evaluate_script("this.scrollWidth <= this.clientWidth")).to eq(true)
      expect(
        element.evaluate_script("this.getBoundingClientRect().right <= window.innerWidth"),
      ).to eq(true)
    end
    page.current_window.resize_to(1440, 900)
    expect(
      find(".crm-sync-activity__attempt").evaluate_script("getComputedStyle(this).display"),
    ).to eq("table-row")
  end
end
