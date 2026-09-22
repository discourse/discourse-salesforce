# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::AdminController do
  include_context "with salesforce spec helper"

  fab!(:admin)

  describe "#authorize" do
    before { sign_in(admin) }

    it "redirects to the Salesforce authorization server with PKCE" do
      get "/salesforce/admin/authorize"

      uri = URI(response.location)
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(
        "https://login.salesforce.com/services/oauth2/authorize",
      )

      params = URI.decode_www_form(uri.query).to_h
      expect(params["client_id"]).to eq("SALESFORCE_CLIENT_ID")
      expect(params["redirect_uri"]).to eq(Discourse.base_url)
      expect(params["response_type"]).to eq("code")
      expect(params["code_challenge_method"]).to eq("S256")
      # An unpadded base64url SHA-256 digest is always 43 characters.
      expect(params["code_challenge"]).to match(/\A[A-Za-z0-9\-_]{43}\z/)
    end
  end
end
