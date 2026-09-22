# frozen_string_literal: true

RSpec.describe Auth::SalesforceAuthenticator do
  subject(:authenticator) { described_class.new }

  before do
    SiteSetting.salesforce_client_id = "client_id"
    SiteSetting.salesforce_client_secret = "client_secret"
  end

  it "requires the login toggle independently of API integration" do
    expect(authenticator.enabled?).to eq(false)

    SiteSetting.salesforce_login_enabled = true

    expect(authenticator.enabled?).to eq(true)
    expect(SiteSetting.salesforce_enabled).to eq(false)
  end

  it "enables PKCE for the authorization code flow" do
    omniauth =
      Class
        .new do
          attr_reader :provider_options

          def provider(_name, **options)
            @provider_options = options
          end
        end
        .new

    authenticator.register_middleware(omniauth)

    strategy_options = { client_options: {} }
    strategy = stub(options: strategy_options)
    omniauth.provider_options[:setup].call("omniauth.strategy" => strategy)

    expect(strategy_options[:pkce]).to eq(true)
  end

  %i[
    salesforce_client_id
    salesforce_client_secret
    salesforce_authorization_server_url
  ].each do |setting|
    it "disables login when #{setting} is cleared" do
      SiteSetting.salesforce_login_enabled = true
      SiteSetting.set(setting, "")

      expect(authenticator.enabled?).to eq(false)
    end

    it "rejects enabling login without #{setting}" do
      SiteSetting.set(setting, "")

      expect { SiteSetting.salesforce_login_enabled = true }.to raise_error(
        Discourse::InvalidParameters,
      )
    end
  end
end
