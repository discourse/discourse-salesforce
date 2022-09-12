# frozen_string_literal: true

RSpec.shared_context "salesforce spec helper" do
  let(:access_token) { "SALESFORCE_ACCESS_TOKEN" }
  let(:instance_url) { "https://test.my.salesforce.com/" }

  before do
    SiteSetting.salesforce_enabled = true
    SiteSetting.salesforce_client_id = "SALESFORCE_CLIENT_ID"
    Salesforce::Api.any_instance.stubs(:jwt_assertion).returns("SALESFORCE_PRIVATE_KEY")
    stub_request(:post, "https://login.salesforce.com/services/oauth2/token").
      with(body: { "assertion" => "SALESFORCE_PRIVATE_KEY", "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer" }).
      to_return(status: 200, body: %({"access_token":"#{access_token}","instance_url":"#{instance_url}"}), headers: {})
  end

  def api_path
    "#{instance_url}services/data/v49.0/sobjects"
  end
end
