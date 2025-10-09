# frozen_string_literal: true

RSpec.shared_context "with salesforce spec helper" do
  let(:access_token) { "SALESFORCE_ACCESS_TOKEN" }
  let(:instance_url) { "https://test.my.salesforce.com/" }
  let(:api_response_status) { 200 }
  let(:api_response_body) { %({"access_token":"#{access_token}","instance_url":"#{instance_url}"}) }

  before do
    SiteSetting.salesforce_enabled = true
    SiteSetting.salesforce_client_id = "SALESFORCE_CLIENT_ID"
    SiteSetting.salesforce_username = "SALESFORCE_API_USERNAME"
    SiteSetting.salesforce_rsa_private_key = "SALESFORCE_PRIVATE_KEY"

    Salesforce::Api.any_instance.stubs(:jwt_assertion).returns("SALESFORCE_PRIVATE_KEY")
    stub_request(:post, "https://login.salesforce.com/services/oauth2/token").with(
      body: {
        "assertion" => "SALESFORCE_PRIVATE_KEY",
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
      },
    ).to_return(status: api_response_status, body: api_response_body, headers: {})
  end

  def api_path
    "#{instance_url}services/data/v49.0/sobjects"
  end
end
