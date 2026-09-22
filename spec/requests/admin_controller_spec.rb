# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::AdminController do
  include_context "with salesforce spec helper"

  fab!(:admin)

  describe "#authorize" do
    before { sign_in(admin) }

    it "redirects to the Salesforce authorization server with PKCE" do
      described_class.any_instance.stubs(:pkce_code_challenge).returns("challenge")

      get "/salesforce/admin/authorize"

      uri = URI(response.location)
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(
        "https://login.salesforce.com/services/oauth2/authorize",
      )
      expect(URI.decode_www_form(uri.query).to_h).to eq(
        {
          "client_id" => "SALESFORCE_CLIENT_ID",
          "redirect_uri" => Discourse.base_url,
          "response_type" => "code",
          "code_challenge" => "challenge",
          "code_challenge_method" => "S256",
        },
      )
    end
  end
end
