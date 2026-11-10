# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::SyncConfigurationController do
  fab!(:admin)
  fab!(:user)
  fab!(:sync_group) { Fabricate(:group, name: "community-members") }

  before do
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
  end

  describe "disabled experimental feature" do
    it "hides the page and blocks all configuration endpoints without changing stored data" do
      sign_in(admin)
      record = Fabricate(:sync_configuration, name: "Saved configuration")
      SiteSetting.enable_guided_sync_configuration = false

      get "/admin/plugins/discourse-salesforce/configurations"
      expect(response).to have_http_status(:not_found)
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response).to have_http_status(:not_found)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: {
               name: "New",
             },
           }
      expect(response).to have_http_status(:not_found)
      put "/salesforce/admin/guided-sync/configurations/#{record.id}.json",
          params: {
            configuration: {
              name: "Changed",
            },
          }
      expect(response).to have_http_status(:not_found)
      delete "/salesforce/admin/guided-sync/configurations/#{record.id}.json"
      expect(response).to have_http_status(:not_found)
      expect(DiscourseCrm::SyncConfiguration.pluck(:id, :name)).to eq(
        [[record.id, "Saved configuration"]],
      )
    end
  end

  describe "#index" do
    it "renders the admin application when opening configurations directly" do
      sign_in(admin)

      get "/admin/plugins/discourse-salesforce/configurations"

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Discourse-Route"]).to eq("discourse_crm/sync_configuration/index")
      get "/admin/plugins/discourse-salesforce/configurations"
      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Discourse-Route"]).to eq("discourse_crm/sync_configuration/index")
    end

    it "rejects non-admin users" do
      sign_in(user)

      get "/admin/plugins/discourse-salesforce/configurations"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "credential status" do
    it "reports existing plugin credential presence without exposing secrets or verifying access" do
      sign_in(admin)
      SiteSetting.salesforce_client_id = ""
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response.parsed_body.fetch("credentials_configured")).to eq(false)
      SiteSetting.salesforce_client_id = "test-client"
      SiteSetting.salesforce_username = "test@example.com"
      SiteSetting.salesforce_rsa_private_key = "test-private-key"
      SiteSetting.salesforce_authorization_server_url = "https://login.salesforce.com"
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response.parsed_body).to include(
        "configurations" => [],
        "credentials_configured" => true,
      )
    end
  end

  describe "#fields" do
    include_context "with salesforce spec helper"

    it "loads writable fields for the selected object" do
      custom_field = Fabricate(:user_field, name: "Job title")
      sign_in(admin)
      %w[Lead Contact].each do |object|
        field = {
          name: "#{object}_Detail__c",
          label: "Detail",
          type: "string",
          custom: true,
          createable: true,
          updateable: true,
        }
        stub_request(:get, "#{api_path}/#{object}/describe").to_return(
          body: {
            fields: [
              field,
              { name: "Id", createable: false, updateable: false },
              { name: "Formula__c", calculated: true, createable: true },
            ],
          }.to_json,
        )
        get "/salesforce/admin/guided-sync/fields.json", params: { object: object }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.fetch("fields")).to eq([field.stringify_keys])
        expect(response.parsed_body.fetch("custom_sources")).to include(
          "id" => "user_field_#{custom_field.id}",
          "name" => "Job title",
          "type" => "text",
        )
      end
    end

    it "returns a safe error when Salesforce is unavailable" do
      sign_in(admin)
      stub_request(:get, "#{api_path}/Lead/describe").to_return(
        status: 503,
        body: "private upstream details",
      )
      get "/salesforce/admin/guided-sync/fields.json", params: { object: "Lead" }
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body.fetch("errors")).to eq(
        [I18n.t("salesforce.error.connection.temporary")],
      )
    end

    it "distinguishes authentication, permission, rate limit and network failures" do
      sign_in(admin)
      {
        401 => "authentication",
        403 => "permissions",
        429 => "rate_limit",
      }.each do |status, category|
        stub_request(:get, "#{api_path}/Lead/describe").to_return(
          status: status,
          body: "private upstream details",
        )
        get "/salesforce/admin/guided-sync/fields.json", params: { object: "Lead" }
        expect(response.parsed_body).to eq(
          "error_type" => category,
          "errors" => [I18n.t("salesforce.error.connection.#{category}")],
        )
      end
      stub_request(:get, "#{api_path}/Lead/describe").to_timeout
      get "/salesforce/admin/guided-sync/fields.json", params: { object: "Lead" }
      expect(response.parsed_body["error_type"]).to eq("temporary")
    end

    it "restricts metadata requests to admins, the feature flag, and supported objects" do
      sign_in(admin)
      get "/salesforce/admin/guided-sync/fields.json", params: { object: "Account" }
      expect(response).to have_http_status(:bad_request)
      SiteSetting.enable_guided_sync_configuration = false
      get "/salesforce/admin/guided-sync/fields.json", params: { object: "Lead" }
      expect(response).to have_http_status(:not_found)
      SiteSetting.enable_guided_sync_configuration = true
      sign_in(user)
      get "/salesforce/admin/guided-sync/fields.json", params: { object: "Lead" }
      expect(response).to have_http_status(:forbidden)
      expect(a_request(:get, %r{/sobjects/})).not_to have_been_made
    end
  end

  describe "available groups" do
    it "returns groups with only eligible members counted" do
      SiteSetting.allow_anonymous_mode = true
      anonymous_user = Fabricate(:user, trust_level: 1)
      AnonymousUser.create!(user: anonymous_user, master_user: user, active: true)
      members = [
        user,
        Fabricate(:user, suspended_till: 1.day.ago),
        Fabricate(:user, active: false),
        Fabricate(:user, staged: true),
        Fabricate(:user, suspended_till: 1.day.from_now),
        anonymous_user,
        Discourse.system_user,
      ]
      members.each { |member| sync_group.add(member) }
      bot_group = Fabricate(:group)
      bot_group.add(Discourse.system_user)
      sign_in(admin)

      get "/salesforce/admin/guided-sync/configurations.json"

      expect(response.parsed_body.fetch("groups")).to include(
        "id" => sync_group.id,
        "name" => sync_group.name,
        "user_count" => 2,
      )
      expect(response.parsed_body.fetch("groups")).to include(
        "id" => bot_group.id,
        "name" => bot_group.name,
        "user_count" => 0,
      )
      expect(
        response.parsed_body.fetch("groups").map { |group| group.fetch("name") },
      ).not_to include("everyone")
    end
  end

  describe "configuration persistence" do
    include_context "with salesforce spec helper"

    before do
      %w[Lead Contact].each do |object|
        stub_request(:get, "#{api_path}/#{object}/describe").to_return(
          body: {
            fields:
              %w[Email FirstName LastName Company].map do |name|
                { name: name, type: "string", createable: true, updateable: true }
              end,
          }.to_json,
        )
      end
    end

    let(:configuration) do
      {
        name: "Lead sync",
        object: "Lead",
        group_ids: [sync_group.id],
        schedule: "daily",
        backfill: true,
        mappings: [
          { id: 1, source: "last", destination: "LastName", policy: "keep" },
          { id: 2, source: "static", value: "Unknown", destination: "Company", policy: "keep" },
        ],
      }
    end

    it "pins new and updated configurations to the instance returned by authentication" do
      sign_in(admin)
      record_id = nil

      %w[post put].each do |method|
        SiteSetting.salesforce_instance_url = "https://previous.salesforce.com/"
        Discourse.redis.del(Salesforce::Api::ACCESS_TOKEN_KEY)
        path =
          "/salesforce/admin/guided-sync/configurations#{record_id ? "/#{record_id}" : ""}.json"

        public_send(method, path, params: { configuration: configuration }, as: :json)

        expect(response).to have_http_status(method == "post" ? :created : :ok)
        record_id = response.parsed_body.dig("configuration", "id")
        record = DiscourseCrm::SyncConfiguration.find(record_id)
        expect(record.account).to eq(instance_url)
        expect(record.connection_changed?).to eq(false)
        expect(DiscourseCrm::SyncConfiguration.active).to include(record)
      end
    end

    it "saves multiple groups and rejects missing or unrestricted scopes" do
      sign_in(admin)
      second_group = Fabricate(:group)
      configuration[:group_ids] = [sync_group.id, second_group.id, sync_group.id]
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("configuration", "groups")).to eq(
        [sync_group.name, second_group.name].sort,
      )
      expect(response.parsed_body.dig("configuration", "connection_changed")).to eq(false)
      expect(response.parsed_body.dig("configuration", "group_ids")).to contain_exactly(
        sync_group.id,
        second_group.id,
      )

      [
        [],
        [sync_group.id, Group.maximum(:id) + 1],
        [Group::AUTO_GROUPS[:everyone]],
        [sync_group.name],
      ].each do |ids|
        configuration[:group_ids] = ids
        post "/salesforce/admin/guided-sync/configurations.json",
             params: {
               configuration: configuration,
             },
             as: :json
        expect(response).to have_http_status(:bad_request)
      end
    end

    it "persists static text and rejects blank or oversized values" do
      sign_in(admin)
      configuration[:mappings][1] = {
        source: "static",
        destination: "Company",
        policy: "overwrite",
        value: "Discourse",
      }
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("configuration", "mappings", 1, "value")).to eq("Discourse")
      [nil, "  ", "a" * 1001].each do |value|
        configuration[:mappings][1][:value] = value
        post "/salesforce/admin/guided-sync/configurations.json",
             params: {
               configuration: configuration,
             },
             as: :json
        expect(response).to have_http_status(:bad_request)
      end
    end

    it "validates mappings before activating and does not requeue backfill on ordinary edits" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration:
               configuration.merge(
                 mappings: [{ source: "last", destination: "Bogus__c", policy: "overwrite" }],
               ),
           },
           as: :json
      expect(response).to have_http_status(:bad_request)
      expect(DiscourseCrm::SyncConfiguration.active).to be_empty
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      expect(response).to have_http_status(:created)
      id = response.parsed_body.fetch("configuration").fetch("id")
      Jobs::SyncSalesforceConfiguration.clear
      put "/salesforce/admin/guided-sync/configurations/#{id}.json",
          params: {
            configuration: configuration.merge(name: "Renamed"),
          },
          as: :json
      expect(response).to have_http_status(:ok)
      expect(Jobs::SyncSalesforceConfiguration.jobs).to be_empty
      put "/salesforce/admin/guided-sync/configurations/#{id}.json",
          params: {
            configuration: configuration.merge(backfill: false),
          },
          as: :json
      expect(response).to have_http_status(:ok)
      put "/salesforce/admin/guided-sync/configurations/#{id}.json",
          params: {
            configuration: configuration,
          },
          as: :json
      expect(response).to have_http_status(:ok)
      expect(Jobs::SyncSalesforceConfiguration.jobs.size).to eq(1)
    end

    it "rejects custom objects and nonexistent groups" do
      sign_in(admin)
      [
        configuration.merge(object: "DiscourseContact__c"),
        configuration.merge(group_ids: [Group.maximum(:id) + 1]),
      ].each do |invalid|
        post "/salesforce/admin/guided-sync/configurations.json",
             params: {
               configuration: invalid,
             },
             as: :json
        expect(response).to have_http_status(:bad_request)
      end
      expect(DiscourseCrm::SyncConfiguration.all).to be_empty
    end

    it "stores independent Lead and Contact configurations" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      expect(response).to have_http_status(:created)
      lead = response.parsed_body.fetch("configuration")
      expect(lead.fetch("group_ids")).to eq([sync_group.id])
      expect(
        Jobs::SyncSalesforceConfiguration.jobs.any? do |job|
          job["args"].first["configuration_id"] == lead["id"]
        end,
      ).to eq(true)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration.merge(name: "Contact sync", object: "Contact"),
           },
           as: :json
      expect(response).to have_http_status(:created)
      contact = response.parsed_body.fetch("configuration")

      put "/salesforce/admin/guided-sync/configurations/#{lead.fetch("id")}.json",
          params: {
            configuration: configuration.merge(name: "Partner sync", backfill: false),
          },
          as: :json
      expect(response).to have_http_status(:ok)
      updated = response.parsed_body.fetch("configuration")
      expect(updated.slice("id", "name", "backfill")).to eq(
        "id" => lead.fetch("id"),
        "name" => "Partner sync",
        "backfill" => false,
      )
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(
        response.parsed_body.fetch("configurations").map { |record| record.except("sync_status") },
      ).to contain_exactly(updated.except("sync_status"), contact.except("sync_status"))

      delete "/salesforce/admin/guided-sync/configurations/#{lead.fetch("id")}.json"
      expect(response).to have_http_status(:no_content)
      expect(DiscourseCrm::SyncConfiguration.pluck(:id)).to eq([contact.fetch("id")])
      delete "/salesforce/admin/guided-sync/configurations/#{lead.fetch("id")}.json"
      expect(response).to have_http_status(:not_found)
    end

    it "rejects post sync configurations while unavailable" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration.merge(kind: "posts", object: "Case"),
           },
           as: :json
      expect(response).to have_http_status(:bad_request)
      expect(DiscourseCrm::SyncConfiguration.all).to be_empty
    end

    it "rejects invalid configurations and changes to the target object" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration.merge(name: ""),
           },
           as: :json
      expect(response).to have_http_status(:bad_request)
      expect(DiscourseCrm::SyncConfiguration.all).to be_empty
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      record = response.parsed_body.fetch("configuration")
      put "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json",
          params: {
            configuration: configuration.merge(object: "Contact"),
          },
          as: :json
      expect(response).to have_http_status(:bad_request)
      expect(DiscourseCrm::SyncConfiguration.pluck(:id, :object)).to eq(
        [[record.fetch("id"), "Lead"]],
      )
    end

    it "rejects non-admin configuration reads and writes" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      record = response.parsed_body.fetch("configuration")
      sign_in(user)
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response).to have_http_status(:forbidden)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      expect(response).to have_http_status(:forbidden)
      put "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json",
          params: {
            configuration: configuration.merge(name: "Changed"),
          },
          as: :json
      expect(response).to have_http_status(:forbidden)
      delete "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json"
      expect(response).to have_http_status(:forbidden)
      expect(DiscourseCrm::SyncConfiguration.pluck(:id, :name)).to eq(
        [[record.fetch("id"), "Lead sync"]],
      )
    end
  end
  describe "#configurations with multiple CRM providers" do
    include_context "with hubspot spec helper"

    it "offers only enabled providers with credentials, without exposing credentials" do
      sign_in(admin)
      SiteSetting.salesforce_enabled = false
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.slice("targets", "credentials_configured")).to eq(
        "targets" => [{ "provider" => "hubspot", "object" => "Contact" }],
        "credentials_configured" => true,
      )
      SiteSetting.salesforce_enabled = true
      SiteSetting.salesforce_client_id = "client"
      SiteSetting.salesforce_username = "user"
      SiteSetting.salesforce_rsa_private_key = "key"
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response.parsed_body.fetch("targets")).to eq(
        [
          { "provider" => "salesforce", "object" => "Lead" },
          { "provider" => "salesforce", "object" => "Contact" },
          { "provider" => "hubspot", "object" => "Contact" },
        ],
      )
      SiteSetting.hubspot_access_token = ""
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(
        response.parsed_body.fetch("targets").map { |target| target.fetch("provider") }.uniq,
      ).to eq(["salesforce"])
      SiteSetting.hubspot_access_token = "HUBSPOT_ACCESS_TOKEN"
      SiteSetting.hubspot_enabled = false
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(
        response.parsed_body.fetch("targets").map { |target| target.fetch("provider") }.uniq,
      ).to eq(["salesforce"])
    end
  end

  describe "#fields for HubSpot" do
    include_context "with hubspot spec helper"

    it "loads HubSpot contact fields when Salesforce is disabled and rejects unsupported targets" do
      sign_in(admin)
      SiteSetting.salesforce_enabled = false
      get "/salesforce/admin/guided-sync/fields.json",
          params: {
            provider: "hubspot",
            object: "Contact",
          }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("fields").map { |field| field.fetch("name") }).to eq(
        hubspot_properties.pluck(:name),
      )
      get "/salesforce/admin/guided-sync/fields.json",
          params: {
            provider: "hubspot",
            object: "Lead",
          }
      expect(response).to have_http_status(:bad_request)
      get "/salesforce/admin/guided-sync/fields.json",
          params: {
            provider: "unknown",
            object: "Contact",
          }
      expect(response).to have_http_status(:bad_request)
      SiteSetting.hubspot_access_token = ""
      get "/salesforce/admin/guided-sync/fields.json",
          params: {
            provider: "hubspot",
            object: "Contact",
          }
      expect(response).to have_http_status(:bad_request)
    end

    it "returns actionable HubSpot errors without including upstream bodies" do
      sign_in(admin)
      stub_request(:get, "#{hubspot_url}/properties/contacts").to_return(
        status: 403,
        body: "private details",
      )
      get "/salesforce/admin/guided-sync/fields.json",
          params: {
            provider: "hubspot",
            object: "Contact",
          }
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq(
        "error_type" => "permissions",
        "errors" => [I18n.t("hubspot.error.connection.permissions")],
      )
    end
  end

  describe "#save_configuration for HubSpot" do
    include_context "with hubspot spec helper"

    let(:hubspot_configuration) do
      {
        name: "HubSpot contacts",
        provider: "hubspot",
        object: "Contact",
        schedule: "daily",
        group_ids: [sync_group.id],
        backfill: true,
        mappings: [{ source: "last", destination: "lastname", policy: "keep" }],
      }
    end

    it "saves a provider-scoped configuration with Salesforce disabled and keeps its provider immutable" do
      sign_in(admin)
      SiteSetting.salesforce_enabled = false
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: hubspot_configuration,
           },
           as: :json
      expect(response).to have_http_status(:created)
      record = DiscourseCrm::SyncConfiguration.find(response.parsed_body.dig("configuration", "id"))
      expect(record.attributes.slice("provider", "object", "account")).to eq(
        "provider" => "hubspot",
        "object" => "Contact",
        "account" => "12345",
      )
      expect(
        Jobs::SyncSalesforceConfiguration.jobs.map { |job| job["args"].first["configuration_id"] },
      ).to include(record.id)
      SiteSetting.hubspot_portal_id = "67890"
      SiteSetting.hubspot_access_token = "NEW_PORTAL_TOKEN"
      stub_request(
        :post,
        "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
      ).with(body: { tokenKey: "NEW_PORTAL_TOKEN" }).to_return(
        body: { hubId: 67_890, appId: 6789 }.to_json,
      )
      expect(record.connection_changed?).to eq(true)
      put "/salesforce/admin/guided-sync/configurations/#{record.id}.json",
          params: {
            configuration: hubspot_configuration,
          },
          as: :json
      expect(response).to have_http_status(:ok)
      expect(record.reload.account).to eq("67890")
      SiteSetting.salesforce_enabled = true
      SiteSetting.salesforce_client_id = "client"
      SiteSetting.salesforce_username = "user"
      SiteSetting.salesforce_rsa_private_key = "key"
      put "/salesforce/admin/guided-sync/configurations/#{record.id}.json",
          params: {
            configuration: hubspot_configuration.merge(provider: "salesforce"),
          },
          as: :json
      expect(response).to have_http_status(:bad_request)
      expect(record.reload.provider).to eq("hubspot")
    end

    it "rejects disabled HubSpot and incompatible mappings before persisting" do
      sign_in(admin)
      SiteSetting.hubspot_enabled = false
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: hubspot_configuration,
           },
           as: :json
      expect(response).to have_http_status(:bad_request)
      SiteSetting.hubspot_enabled = true
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration:
               hubspot_configuration.merge(
                 mappings: [{ source: "last", destination: "community_posts", policy: "keep" }],
               ),
           },
           as: :json
      expect(response).to have_http_status(:bad_request)
      expect(DiscourseCrm::SyncConfiguration.count).to eq(0)
    end
  end
end
