# frozen_string_literal: true

RSpec.describe ::Hubspot::Api do
  let(:contacts_url) { "https://api.hubapi.com/crm/v3/objects/contacts" }

  before do
    SiteSetting.hubspot_portal_id = "12345"
    SiteSetting.hubspot_access_token = "HUBSPOT_ACCESS_TOKEN"
    Rails.cache.clear
    stub_request(
      :post,
      "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
    ).to_return(body: { hubId: 12_345, appId: 6789 }.to_json)
  end

  describe ".has_credentials?" do
    it "requires both the portal id and the access token" do
      expect(described_class.has_credentials?).to eq(true)

      SiteSetting.hubspot_access_token = ""
      expect(described_class.has_credentials?).to eq(false)

      SiteSetting.hubspot_access_token = "HUBSPOT_ACCESS_TOKEN"
      Rails.cache.clear
      stub_request(
        :post,
        "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
      ).to_return(body: { hubId: 12_345, appId: 6789 }.to_json)
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
  describe "#cached_writable_fields" do
    it "distinguishes boolean checkboxes from other enumeration fields" do
      properties = [
        { name: "binary", label: "Binary", type: "bool", fieldType: "booleancheckbox" },
        {
          name: "confirmed",
          label: "Confirmed",
          type: "enumeration",
          fieldType: "booleancheckbox",
        },
        { name: "choices", label: "Choices", type: "enumeration", fieldType: "checkbox" },
        { name: "status", label: "Status", type: "enumeration", fieldType: "select" },
      ]
      stub_request(:get, "https://api.hubapi.com/crm/v3/properties/contacts").to_return(
        body: { results: properties }.to_json,
      )

      fields = described_class.cached_writable_fields("Contact", refresh: true)

      expect(fields.map { |field| [field["name"], field["type"]] }).to eq(
        [%w[binary boolean], %w[confirmed boolean], %w[choices multipicklist], %w[status picklist]],
      )
    end

    it "filters read-only fields, normalizes property types and isolates cached credentials" do
      request =
        stub_request(:get, "https://api.hubapi.com/crm/v3/properties/contacts").to_return(
          body: {
            results: [
              { name: "email", label: "Email", type: "string" },
              { name: "posts", label: "Posts", type: "number", hubspotDefined: false },
              { name: "groups", label: "Groups", type: "enumeration", fieldType: "checkbox" },
              {
                name: "computed",
                label: "Computed",
                type: "string",
                modificationMetadata: {
                  readOnlyValue: true,
                },
              },
              { name: "calculated", label: "Calculated", type: "number", calculated: true },
            ],
          }.to_json,
        )
      fields = described_class.cached_writable_fields("Contact", refresh: true)
      expect(fields.map { |field| [field["name"], field["type"], field["custom"]] }).to eq(
        [["email", "string", false], ["posts", "double", true], ["groups", "multipicklist", false]],
      )
      described_class.cached_writable_fields("Contact")
      expect(request).to have_been_requested.once
      SiteSetting.hubspot_access_token = "NEW_TOKEN"
      described_class.cached_writable_fields("Contact")
      expect(request).to have_been_requested.twice
    end
  end
  after do
    Discourse.redis.without_namespace.del("hubspot_api:12345:6789:cooldown")
    RateLimiter.new(nil, "hubspot_api:12345:6789", 90, 10, global: true).clear!
  end

  describe "account verification" do
    it "rejects a replacement token from another account before contacting CRM endpoints" do
      described_class.new
      SiteSetting.hubspot_access_token = "OTHER_TOKEN"
      stub_request(
        :post,
        "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
      ).with(body: { tokenKey: "OTHER_TOKEN" }).to_return(
        body: { hubId: 99_999, appId: 6789 }.to_json,
      )

      expect { described_class.new.ping }.to raise_error(Hubspot::InvalidCredentials)
      expect(a_request(:get, contacts_url)).not_to have_been_made
    end

    it "caches verified identity by token and retains the original account on an existing client" do
      info =
        stub_request(
          :post,
          "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
        ).to_return(body: { hubId: 12_345, appId: 6789 }.to_json)
      api = described_class.new
      described_class.new
      SiteSetting.hubspot_portal_id = "99999"

      expect(api.account).to eq("12345")
      expect { described_class.new }.to raise_error(Hubspot::InvalidCredentials)
      expect(info).to have_been_requested.once
    end
  end

  describe "rate limiting" do
    it "limits requests across clients and permits them after the window expires" do
      disabled = RateLimiter.disabled?
      RateLimiter.enable
      freeze_time
      request =
        stub_request(:get, contacts_url).with(query: { limit: 1 }).to_return(
          body: { results: [] }.to_json,
        )
      clients = [described_class.new, described_class.new]
      90.times { |index| clients[index % 2].ping }

      expect { clients.first.ping }.to raise_error(Hubspot::RateLimitExceeded)
      expect(request).to have_been_requested.times(90)
      freeze_time 11.seconds.from_now
      clients.first.ping
      expect(request).to have_been_requested.times(91)
    ensure
      RateLimiter.disable if disabled
    end

    it "honors HubSpot Retry-After and shares cooldowns between clients" do
      request =
        stub_request(:get, contacts_url).with(query: { limit: 1 }).to_return(
          status: 429,
          headers: {
            "Retry-After" => "30",
          },
        )
      2.times do
        expect { described_class.new.ping }.to raise_error(Hubspot::RateLimitExceeded) { |error|
          expect(error.retry_after).to be_between(29, 30)
        }
      end
      expect(request).to have_been_requested.once
    end
  end

  describe "lookup diagnostics" do
    it "silences expected email misses while reporting missing linked contacts" do
      stub_request(:get, contacts_url).to_return(status: 404, body: "missing")
      api = described_class.new
      logger =
        track_log_messages { expect(api.get("objects/contacts", allow_not_found: true)).to be_nil }
      expect(logger.warnings).to be_empty
      logger =
        track_log_messages do
          expect { api.get("objects/contacts") }.to raise_error(Hubspot::InvalidApiResponse)
        end
      expect(logger.warnings).to include(
        "HubSpot request failed: operation=api category=invalid_response status=404",
      )
    end
  end
end
