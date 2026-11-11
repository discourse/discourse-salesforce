# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Hubspot::ContactPropertiesController do
  include_context "with hubspot spec helper"

  fab!(:admin)

  before { SiteSetting.salesforce_enabled = true }

  describe "#index" do
    it "lists contact properties, refreshing the cache on request, and reports HubSpot failures" do
      sign_in(admin)
      stub_hubspot_properties(%w[lifecyclestage hs_analytics_source jobtitle])

      get "/salesforce/admin/hubspot/contact-properties.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("properties").map { |field| field.fetch("name") }).to eq(
        %w[lifecyclestage jobtitle],
      )

      get "/salesforce/admin/hubspot/contact-properties.json", params: { refresh: "true" }
      expect(a_request(:get, hubspot_url("properties/contacts"))).to have_been_made.twice

      stub_request(:get, hubspot_url("properties/contacts")).to_return(status: 401)
      get "/salesforce/admin/hubspot/contact-properties.json", params: { refresh: "true" }
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq(
        "error_type" => "authentication",
        "errors" => [I18n.t("hubspot.error.connection.authentication")],
      )
    end

    it "is unavailable while the provider or the configurations feature is disabled" do
      sign_in(admin)
      stub_hubspot_properties(%w[lifecyclestage])

      SiteSetting.hubspot_enabled = false
      get "/salesforce/admin/hubspot/contact-properties.json"
      expect(response).to have_http_status(:not_found)

      SiteSetting.hubspot_enabled = true
      SiteSetting.enable_guided_sync_configuration = false
      get "/salesforce/admin/hubspot/contact-properties.json"
      expect(response).to have_http_status(:not_found)
    end
  end
end
