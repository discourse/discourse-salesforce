# frozen_string_literal: true

require 'json'

module ::Salesforce

  class InvalidApiResponse < ::StandardError; end
  class InvalidCredentials < ::StandardError; end

  class Api

    VERSION = "49.0".freeze
    INVALID_RESPONSE = "salesforce.error.invalid_response".freeze

    attr_reader :faraday, :path

    def initialize
      set_access_token

      @faraday = Faraday.new(
        url: SiteSetting.salesforce_instance_url,
        headers: { 'Authorization' => "Bearer #{SiteSetting.salesforce_access_token}" }
      )
      @path = "/services/data/v#{VERSION}"
    end

    def get(uri)
      uri = File.join(path, uri)
      response = faraday.get(uri)
    end

    def post(uri, fields)
      uri = File.join(path, uri)
      response = faraday.post(uri, fields.to_json, 'Content-Type': 'application/json')

      case response.status
      when 200, 201
        return JSON.parse response.body
      else
        e = ::Salesforce::InvalidApiResponse.new(response.body.presence || '')
        e.set_backtrace(caller)
        Discourse.warn_exception(e, message: I18n.t(INVALID_RESPONSE), env: { api_uri: uri })
        raise e
      end
    end

    def set_access_token
      return if SiteSetting.salesforce_instance_url.present? && SiteSetting.salesforce_access_token.present?

      response = Faraday.new(
        url: 'https://login.salesforce.com'
      ).post("/services/oauth2/token", {
        grant_type: 'password',
        client_id: SiteSetting.salesforce_client_id,
        client_secret: SiteSetting.salesforce_client_secret,
        username: SiteSetting.salesforce_username,
        password: SiteSetting.salesforce_password
      })

      if response.status != 200
        raise Salesforce::InvalidCredentials
      end

      data = JSON.parse response.body
      SiteSetting.salesforce_access_token = data["access_token"]
      SiteSetting.salesforce_instance_url = data["instance_url"]
    end

    def set_faraday
      faraday 
    end
  end
end
