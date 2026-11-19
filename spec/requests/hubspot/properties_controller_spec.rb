# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Hubspot::PropertiesController do
  include_context "with hubspot spec helper"

  fab!(:admin)

  before { SiteSetting.salesforce_enabled = true }

  describe "#index" do
    it "lists the properties of the requested object, refreshing the cache on request, and reports HubSpot failures" do
      sign_in(admin)
      stub_hubspot_properties(%w[lifecyclestage hs_analytics_source jobtitle])
      stub_hubspot_properties(%w[name plan_tier], object: "company")

      get "/salesforce/admin/hubspot/properties.json", params: { object: "contact" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("properties").map { |field| field.fetch("name") }).to eq(
        %w[lifecyclestage jobtitle],
      )

      get "/salesforce/admin/hubspot/properties.json", params: { object: "company" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("properties").map { |field| field.fetch("name") }).to eq(
        %w[name plan_tier],
      )

      get "/salesforce/admin/hubspot/properties.json",
          params: {
            object: "contact",
            refresh: "true",
          }
      expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.twice

      stub_request(:get, hubspot_url("properties/contacts")).to_return(status: 401)
      get "/salesforce/admin/hubspot/properties.json",
          params: {
            object: "contact",
            refresh: "true",
          }
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq(
        "error_type" => "authentication",
        "errors" => [I18n.t("hubspot.error.connection.authentication")],
      )
    end

    it "serves push fields and Discourse sources for contacts from the same cached metadata" do
      SiteSetting.salesforce_enabled = false
      sign_in(admin)
      stub_request(:get, hubspot_url("properties/contacts")).to_return(
        body: {
          results: [
            { name: "email", label: "Email", type: "string" },
            { name: "firstname", label: "First name", type: "string" },
            { name: "calculated", label: "Calculated", type: "number", calculated: true },
          ],
        }.to_json,
      )
      stub_hubspot_properties(%w[name], object: "company")

      2.times { get "/salesforce/admin/hubspot/properties.json", params: { object: "contact" } }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["properties"].map { |field| field["name"] }).to contain_exactly(
        "email",
        "firstname",
        "calculated",
      )
      expect(response.parsed_body["fields"].map { |field| field["name"] }).to contain_exactly(
        "email",
        "firstname",
      )
      expect(response.parsed_body["custom_sources"]).to eq([])
      expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.once

      get "/salesforce/admin/hubspot/properties.json", params: { object: "company" }
      expect(response.parsed_body.keys).to eq(["properties"])
    end

    it "requires a known object" do
      sign_in(admin)

      get "/salesforce/admin/hubspot/properties.json"
      expect(response).to have_http_status(:bad_request)

      get "/salesforce/admin/hubspot/properties.json", params: { object: "deal" }
      expect(response).to have_http_status(:bad_request)
      expect(a_request(:any, /api.hubapi.com/)).not_to have_been_made
    end

    it "is unavailable while the provider or the configurations feature is disabled" do
      sign_in(admin)
      stub_hubspot_properties(%w[lifecyclestage])

      SiteSetting.hubspot_enabled = false
      get "/salesforce/admin/hubspot/properties.json", params: { object: "contact" }
      expect(response).to have_http_status(:not_found)

      SiteSetting.hubspot_enabled = true
      SiteSetting.enable_guided_sync_configuration = false
      get "/salesforce/admin/hubspot/properties.json", params: { object: "contact" }
      expect(response).to have_http_status(:not_found)
    end
  end
end
