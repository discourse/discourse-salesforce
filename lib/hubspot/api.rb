# frozen_string_literal: true

require "json"

module ::Hubspot
  class Api
    BASE_URL = "https://api.hubapi.com"
    PREFIX = "/crm/v3"
    INVALID_RESPONSE = "hubspot.error.invalid_response"

    attr_reader :faraday

    def self.has_credentials?
      SiteSetting.hubspot_portal_id.present? && SiteSetting.hubspot_access_token.present?
    end

    def initialize
      raise Hubspot::InvalidCredentials if !self.class.has_credentials?

      @faraday =
        Faraday.new(
          url: BASE_URL,
          headers: {
            "Authorization" => "Bearer #{SiteSetting.hubspot_access_token}",
          },
        ) { |builder| builder.adapter FinalDestination::FaradayAdapter }
    end

    def account
      SiteSetting.hubspot_portal_id
    end

    def ping
      get("objects/contacts", limit: 1)
    end

    def get(path, query = {})
      call(path) { |uri| faraday.get(uri, query) }
    end

    private

    def call(path)
      uri = File.join(PREFIX, path)
      response = yield(uri)

      case response.status
      when 200, 201
        JSON.parse(response.body)
      when 204
        nil
      when 401
        raise Hubspot::InvalidCredentials
      else
        error =
          Hubspot::InvalidApiResponse.new(response.body.presence || "", status: response.status)
        error.set_backtrace(caller)
        Discourse.warn_exception(error, message: I18n.t(INVALID_RESPONSE), env: { api_uri: uri })
        raise error
      end
    end
  end
end
