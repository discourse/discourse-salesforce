# frozen_string_literal: true

RSpec.describe ::Hubspot::Api do
  let(:contacts_url) { "https://api.hubapi.com/crm/v3/objects/contacts" }

  before do
    SiteSetting.hubspot_portal_id = "12345"
    SiteSetting.hubspot_access_token = "HUBSPOT_ACCESS_TOKEN"
  end

  describe ".has_credentials?" do
    it "requires both the portal id and the access token" do
      expect(described_class.has_credentials?).to eq(true)

      SiteSetting.hubspot_access_token = ""
      expect(described_class.has_credentials?).to eq(false)

      SiteSetting.hubspot_access_token = "HUBSPOT_ACCESS_TOKEN"
      SiteSetting.hubspot_portal_id = ""
      expect(described_class.has_credentials?).to eq(false)
    end
  end

  describe ".new" do
    it "raises invalid credentials when the access token is blank" do
      SiteSetting.hubspot_access_token = ""

      expect { described_class.new }.to raise_error(Hubspot::InvalidCredentials)
    end

    it "exposes the portal id as the account" do
      expect(described_class.new.account).to eq("12345")
    end
  end

  describe "#ping" do
    it "requests one contact with the bearer token and returns the parsed body" do
      stub_request(:get, contacts_url).with(
        query: {
          limit: 1,
        },
        headers: {
          "Authorization" => "Bearer HUBSPOT_ACCESS_TOKEN",
        },
      ).to_return(status: 200, body: { results: [] }.to_json)

      expect(described_class.new.ping).to eq("results" => [])
    end

    it "raises invalid credentials when HubSpot rejects the token" do
      stub_request(:get, contacts_url).with(query: { limit: 1 }).to_return(status: 401)

      expect { described_class.new.ping }.to raise_error(Hubspot::InvalidCredentials)
    end

    it "raises an invalid api response with the status for other failures" do
      stub_request(:get, contacts_url).with(query: { limit: 1 }).to_return(
        status: 500,
        body: "upstream failure",
      )

      expect { described_class.new.ping }.to raise_error(Hubspot::InvalidApiResponse) { |error|
        expect(error.status).to eq(500)
      }
    end
  end
end
