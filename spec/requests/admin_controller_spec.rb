# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::AdminController do
  include_context "with salesforce spec helper"

  fab!(:admin)

  describe "#authorize" do
    before { sign_in(admin) }

    it "redirects to the Salesforce authorization server" do
      get "/salesforce/admin/authorize"
      expect(response).to redirect_to(
        "https://login.salesforce.com/services/oauth2/authorize?client_id=SALESFORCE_CLIENT_ID&redirect_uri=#{Discourse.base_url}&response_type=code",
      )
    end
  end
end
