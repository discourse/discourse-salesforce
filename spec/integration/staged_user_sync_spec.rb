# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "syncing staged users created from incoming email" do
  include_context "with salesforce spec helper"

  fab!(:group) { Fabricate(:group, incoming_email: "team@example.com") }

  before do
    Jobs.run_immediately!
    SiteSetting.email_in = true
    SiteSetting.salesforce_contact_sync_mode = "overwrite"
    SiteSetting.salesforce_contact_sync_fields = "FirstName"
  end

  it "links the staged user to a matching contact without updating it" do
    stub_salesforce_person_lookup("Contact", "sender@example.com", id: "contact_123")

    Email::Receiver.new(<<~EMAIL).process!
      From: Sender Name <sender@example.com>
      To: team@example.com
      Subject: Hello from the inbox
      Date: Sat, 16 Jan 2016 00:12:43 +0100
      Message-ID: <staged-sender-message@example.com>
      Mime-Version: 1.0
      Content-Type: text/plain

      This message creates a staged user.
    EMAIL

    staged_user = User.find_by_email("sender@example.com")
    expect(staged_user).to be_staged
    expect(staged_user.salesforce_contact_id).to eq("contact_123")
    expect(a_request(:patch, %r{/sobjects/})).not_to have_been_made
  end
end
