# frozen_string_literal: true

require 'json'

module ::Salesforce

  class InvalidApiResponse < ::StandardError; end
  class InvalidCredentials < ::StandardError; end

  class Api

    VERSION = "49.0"
    INVALID_RESPONSE = "salesforce.error.invalid_response"

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

      connection = Faraday.new(url: 'https://login.salesforce.com')
      response = connection.post("/services/oauth2/token") do |req|
        req.body = URI.encode_www_form({
          grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          assertion: JWT.encode(claims, private_key, 'RS256')
        })
      end

      if response.status != 200
        raise Salesforce::InvalidCredentials
      end

      data = JSON.parse response.body
      SiteSetting.salesforce_access_token = data["access_token"]
      SiteSetting.salesforce_instance_url = data["instance_url"]
    end
  
    private
  
    def claims
      {
        iss: SiteSetting.salesforce_client_id,
        sub: "team+salesforce-discourse-dev-ed@discourse.org",
        aud: "https://login.salesforce.com",
        iat: Time.now.utc.to_i,
        exp: Time.now.utc.to_i + 180
      }
    end
  
    def private_key
      OpenSSL::PKey::RSA.new(SiteSetting.salesforce_rsa_private_key)
    end
  end
end
