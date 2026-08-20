# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "auto-creating contacts on signup" do
  include_context "with salesforce spec helper"

  fab!(:user) { Fabricate(:user, active: false) }

  before { SiteSetting.salesforce_contact_auto_create_on_signup = true }

  it "syncs the user when they become active" do
    expect_enqueued_with(job: :sync_salesforce_user, args: { user_id: user.id }) do
      user.update!(active: true)
    end
  end

  it "does not sync an already active user on unrelated changes" do
    user.update!(active: true)

    expect_not_enqueued_with(job: :sync_salesforce_user) { user.update!(name: "Another Name") }
  end

  it "does not sync on activation when the setting is disabled" do
    SiteSetting.salesforce_contact_auto_create_on_signup = false

    expect_not_enqueued_with(job: :sync_salesforce_user) { user.update!(active: true) }
  end
end
