# frozen_string_literal: true

require_relative "../../spec_helper"

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

  context "with contact endpoints" do
    include_context "with hubspot spec helper"

    let(:api) { described_class.new }

    describe "#properties and .cached_properties" do
      it "hides HubSpot's internal property families and caches the rest until refreshed" do
        stub_hubspot_properties(
          %w[lifecyclestage hs_analytics_source hs_email_open hs_v2_date jobtitle hs_sequences_x],
        )

        expect(api.properties.map { |property| property[:name] }).to eq(%w[lifecyclestage jobtitle])
        expect(api.properties.first).to eq(
          name: "lifecyclestage",
          label: "Lifecyclestage",
          type: "string",
          group: "contactinformation",
        )

        described_class.cached_properties
        described_class.cached_properties
        expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.times(3)
        described_class.cached_properties(refresh: true)
        expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.times(4)
      end
    end

    describe "#batch_read_contacts_by_email" do
      it "reads emails in chunks of 100 and concatenates the results" do
        emails = (1..150).map { |index| "user#{index}@example.com" }
        stub_hubspot_batch_read([hubspot_contact(1, "user1@example.com")])

        results = api.batch_read_contacts_by_email(emails, properties: %w[email])

        expect(results.size).to eq(2)
        expect(
          a_request(:post, hubspot_url("objects/contacts/batch/read")).with do |request|
            JSON.parse(request.body).fetch("inputs").size == 100
          end,
        ).to have_been_made.once
        expect(
          a_request(:post, hubspot_url("objects/contacts/batch/read")).with do |request|
            JSON.parse(request.body).fetch("inputs").size == 50
          end,
        ).to have_been_made.once
      end
    end

    describe "#list_contacts" do
      it "requests the selected properties with the cursor" do
        stub_hubspot_contact_list(
          [],
          query: {
            after: "50",
            limit: "100",
            properties: "email,jobtitle",
          },
        )

        api.list_contacts(after: "50", properties: %w[email jobtitle])

        expect(
          a_request(:get, hubspot_url("objects/contacts")).with(
            query: {
              after: "50",
              limit: "100",
              properties: "email,jobtitle",
            },
          ),
        ).to have_been_made.once
      end
    end

    describe "rate limiting" do
      it "raises a rate limited error carrying the retry delay" do
        stub_hubspot_contact_search([], status: 429, headers: { "Retry-After" => "12" })

        expect {
          api.search_contacts_modified_since(Time.zone.now, properties: %w[email])
        }.to raise_error(Hubspot::RateLimited) { |error| expect(error.retry_after).to eq(12) }
      end
    end
  end
end
