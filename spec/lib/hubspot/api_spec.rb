# frozen_string_literal: true

require_relative "../../spec_helper"

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
      SiteSetting.hubspot_portal_id = ""
      expect(described_class.has_credentials?).to eq(false)
    end
  end

  describe ".new" do
    it "raises invalid credentials when the access token is blank" do
      SiteSetting.hubspot_access_token = ""

      expect { described_class.new }.to raise_error(Hubspot::InvalidCredentials)
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

    describe ".cached_properties" do
      it "hides HubSpot's internal property families and caches the rest until refreshed" do
        stub_hubspot_properties(
          %w[lifecyclestage hs_analytics_source hs_email_open hs_v2_date jobtitle hs_sequences_x],
        )

        expect(api.cached_properties("contact").map { |property| property[:name] }).to eq(
          %w[lifecyclestage jobtitle],
        )
        expect(api.cached_properties("contact").first).to eq(
          name: "lifecyclestage",
          label: "Lifecyclestage",
          type: "string",
          group: "contactinformation",
        )

        described_class.cached_properties("contact")
        described_class.cached_properties("contact")
        expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.once
        described_class.cached_properties("contact", refresh: true)
        expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.twice
      end

      it "caches company properties separately from contact properties" do
        stub_hubspot_properties(%w[lifecyclestage])
        stub_hubspot_properties(%w[name hs_analytics_x plan_tier], object: "company")

        described_class.cached_properties("contact")
        companies = described_class.cached_properties("company")
        described_class.cached_properties("company")

        expect(companies.map { |property| property[:name] }).to eq(%w[name plan_tier])
        expect(a_request(:get, hubspot_url("properties/companies"))).to have_been_made.once
        expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.once
      end
    end

    describe "#batch_read_companies" do
      it "rejects a pending company lookup even when all requested IDs are present" do
        stub_request(:post, hubspot_url("objects/companies/batch/read")).to_return(
          body: { status: "PENDING", results: [hubspot_company(1, name: "Acme")] }.to_json,
        )
        expect { api.batch_read_companies(%w[1], properties: %w[name]) }.to raise_error(
          Hubspot::InvalidApiResponse,
        ) { |error| expect(error.diagnostics).to eq(codes: ["INCOMPLETE_COMPANY_BATCH_READ"]) }
      end

      it "reads ids in chunks of 100 and reports the ids HubSpot no longer has" do
        ids = (1..150).map(&:to_s)
        stub_hubspot_company_batch_read(
          [hubspot_company(1, name: "Acme")],
          ids: ids.first(100),
          errors: [{ category: "OBJECT_NOT_FOUND", context: { ids: %w[2 3] } }],
        )
        stub_hubspot_company_batch_read([hubspot_company(150, name: "Globex")], ids: ids.last(50))

        results, missing = api.batch_read_companies(ids, properties: %w[name])

        expect(results.map { |company| company["id"] }).to eq(%w[1 150])
        expect(missing).to eq(%w[2 3])
        expect(
          a_request(:post, hubspot_url("objects/companies/batch/read")).with(
            body: hash_including("properties" => %w[name]),
          ),
        ).to have_been_made.twice
      end

      it "raises when a batch reports an error other than a missing record" do
        stub_hubspot_company_batch_read(
          [],
          errors: [{ category: "VALIDATION_ERROR", context: { ids: %w[1] } }],
        )

        expect { api.batch_read_companies(%w[1], properties: %w[name]) }.to raise_error(
          Hubspot::InvalidApiResponse,
          /VALIDATION_ERROR/,
        )
      end
    end

    describe "#batch_read_contacts_by_email" do
      it "preserves a 404 when the response does not confirm a missing contact" do
        stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
          status: 404,
          body: "Not found",
        )
        expect {
          api.batch_read_contacts_by_email(["ada@example.com"], properties: %w[email])
        }.to raise_error(Hubspot::InvalidApiResponse) { |error| expect(error.status).to eq(404) }
      end

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

      fields = described_class.new.cached_writable_fields("contact", refresh: true)

      expect(fields.map { |field| [field["name"], field["type"]] }).to eq(
        [%w[binary boolean], %w[confirmed boolean], %w[choices multipicklist], %w[status picklist]],
      )
    end

    it "filters read-only fields, falls back to property names and caches metadata per token" do
      request =
        stub_request(:get, "https://api.hubapi.com/crm/v3/properties/contacts").to_return(
          body: {
            results: [
              { name: "email", type: "string" },
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
      fields = described_class.new.cached_writable_fields("contact", refresh: true)
      expect(fields.map { |field| [field["name"], field["type"], field["custom"]] }).to eq(
        [["email", "string", false], ["posts", "double", true], ["groups", "multipicklist", false]],
      )
      expect(fields.first["label"]).to eq("email")
      described_class.new.cached_writable_fields("contact")
      expect(request).to have_been_requested.once
      SiteSetting.hubspot_access_token = "NEW_TOKEN"
      described_class.new.cached_writable_fields("contact")
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

    {
      "a null response" => nil,
      "a non-object response" => [],
      "a missing Hub ID" => {
      },
      "an invalid Hub ID" => {
        hubId: "invalid",
      },
    }.each do |description, invalid_info|
      it "recovers from #{description} without caching the invalid token information" do
        info =
          stub_request(
            :post,
            "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
          ).to_return(
            { body: invalid_info.to_json },
            { body: { hubId: 12_345, appId: 6789 }.to_json },
          )
        expect { described_class.new }.to raise_error(Hubspot::InvalidCredentials)
        expect(described_class.new.account).to eq("12345")
        expect(info).to have_been_requested.twice
      end
    end

    it "honors token verification cooldowns across clients" do
      info =
        stub_request(
          :post,
          "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
        ).to_return(status: 429, headers: { "Retry-After" => "30" })
      2.times do
        expect { described_class.new }.to raise_error(Hubspot::RateLimited) { |error|
          expect(error.retry_after).to be_between(29, 30)
        }
      end
      expect(info).to have_been_requested.once
    ensure
      fingerprint = Digest::SHA256.hexdigest(SiteSetting.hubspot_access_token)
      Discourse.redis.without_namespace.del("hubspot_api:12345:#{fingerprint}:cooldown")
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

      expect { clients.first.ping }.to raise_error(Hubspot::RateLimited)
      expect(request).to have_been_requested.times(90)
      freeze_time 11.seconds.from_now
      clients.first.ping
      expect(request).to have_been_requested.times(91)
    ensure
      RateLimiter.disable if disabled
    end

    it "reports daily quota exhaustion instead of scheduling a short cooldown" do
      stub_request(:get, contacts_url).with(query: { limit: 1 }).to_return(
        status: 429,
        body: { policyName: "DAILY" }.to_json,
      )
      expect { described_class.new.ping }.to raise_error(Hubspot::DailyQuotaExceeded) { |error|
        expect(error.retryable?).to eq(false)
      }
      expect(Discourse.redis.without_namespace.exists?("hubspot_api:12345:6789:cooldown")).to eq(
        false,
      )
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
        expect { described_class.new.ping }.to raise_error(Hubspot::RateLimited) { |error|
          expect(error.retry_after).to be_between(29, 30)
        }
      end
      expect(request).to have_been_requested.once
    end
  end

  describe "lookup diagnostics" do
    it "logs validation codes and property names without response values or messages" do
      stub_request(:get, contacts_url).to_return(
        status: 400,
        body: {
          category: "VALIDATION_ERROR",
          correlationId: "trace-123",
          message: "private response",
          errors: [
            {
              code: "INVALID_OPTION",
              name: "lifecyclestage",
              message: "private value",
              context: {
                value: ["private value"],
              },
            },
          ],
        }.to_json,
      )
      api = described_class.new
      logger =
        track_log_messages do
          expect { api.get("objects/contacts") }.to raise_error(Hubspot::InvalidApiResponse)
        end
      expect(logger.warnings.join).to include("INVALID_OPTION", "lifecyclestage", "trace-123")
      expect(logger.warnings.join).not_to include("private response", "private value")
    end

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
