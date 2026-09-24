# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

module Salesforce
  class AdminController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    skip_before_action :check_xhr, :preload_json

    def authorize
      query =
        URI.encode_www_form(
          client_id: SiteSetting.salesforce_client_id,
          redirect_uri: Discourse.base_url,
          response_type: "code",
          code_challenge: pkce_code_challenge,
          code_challenge_method: "S256",
        )

      redirect_to "#{SiteSetting.salesforce_authorization_server_url}/services/oauth2/authorize?#{query}",
                  allow_other_host: true
    end

    private

    # The code this redirect returns is never redeemed: the round trip only exists
    # to capture the user's consent for the JWT bearer grant. Discarding the
    # verifier is deliberate, and leaves the emitted code unusable by anyone.
    def pkce_code_challenge
      verifier = SecureRandom.urlsafe_base64(64, false)
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end
  end
end
