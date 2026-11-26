# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Salesforce pull configuration" do
  include_context "with salesforce spec helper"

  fab!(:admin)

  let(:configurations_page) { PageObjects::Pages::SalesforceConfigurations.new }

  before do
    SiteSetting.enable_guided_sync_configuration = true
    %w[Lead Contact].each do |object|
      stub_request(:get, "#{api_path}/#{object}/describe").to_return(
        body: {
          fields: [
            { name: "Name", label: "Full Name", type: "string" },
            { name: "Website", label: "Website", type: "url" },
            { name: "Title", label: "Title", type: "string" },
          ],
        }.to_json,
      )
    end
    stub_request(:get, query_path).with(query: hash_including({})).to_return(
      body: { records: [] }.to_json,
    )
    sign_in(admin)
  end

  it "pulls Salesforce Leads and Contacts in separate configurations" do
    configurations_page.visit.start_pull

    expect(configurations_page).to have_pull_object("Salesforce - Leads")
    expect(configurations_page).to have_property("Name", destination: "Name")
    expect(configurations_page).to have_property("Website", destination: "Website")

    configurations_page.add_property("Title").save

    expect(configurations_page).to have_configuration(
      "Pull Salesforce leads",
      type: "Pull users from CRM",
      scope: "All users",
    )
    lead_pull = DiscourseCrm::SyncConfiguration.find_by(object: "Lead")
    expect(lead_pull).to have_attributes(provider: "salesforce", direction: "inbound")
    expect(lead_pull.mappings.pluck("source")).to eq(%w[Name Website Title])

    configurations_page.start_pull

    expect(configurations_page).to have_pull_object("Salesforce - Contacts")
    configurations_page.save

    expect(configurations_page).to have_configuration(
      "Pull Salesforce contacts",
      type: "Pull users from CRM",
      scope: "All users",
    )
    expect(configurations_page).to have_pull_disabled
  end
end
