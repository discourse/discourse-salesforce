# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Salesforce OAuth2" do
  before do
    SiteSetting.salesforce_client_id = "SALESFORCE_CLIENT_ID"
    SiteSetting.salesforce_client_secret = "SALESFORCE_CLIENT_SECRET"
    SiteSetting.salesforce_login_enabled = true
  end

  it "uses the configured authorization endpoint and callback for unauthenticated login requests" do
    post "/auth/salesforce",
         params: {
           client_options: {
             site: "https://attacker.example",
           },
           redirect_uri: "https://attacker.example/callback",
         }

    expect(response.status).to eq(302)
    expect(response.location).to start_with(
      "https://login.salesforce.com/services/oauth2/authorize",
    )
    expect(response.location).to include(
      Rack::Utils.escape("#{Discourse.base_url}/auth/salesforce/callback"),
    )
  end
end
