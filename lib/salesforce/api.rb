# frozen_string_literal: true

require 'json'

module ::Salesforce

  class InvalidApiResponse < ::StandardError; end
  class InvalidCredentials < ::StandardError; end

  class Api

    VERSION = "49.0"
    INVALID_RESPONSE = "salesforce.error.invalid_response"
    APP_NOT_APPROVED = "dashboard.salesforce.app_not_approved"

    attr_reader :faraday, :prefix

    def initialize
      set_access_token

      @faraday = Faraday.new(
        url: SiteSetting.salesforce_instance_url,
        headers: { 'Authorization' => "Bearer #{SiteSetting.salesforce_access_token}" }
      )
      @prefix = "/services/data/v#{VERSION}"
    end

    def get(path)
      call(path) do |uri|
        faraday.get(uri)
      end
    end

    def post(path, fields)
      call(path) do |uri|      
        faraday.post(uri, fields.to_json, 'Content-Type': 'application/json')
      end
    end

    def call(path)
      uri = File.join(prefix, path)
      response = yield(uri)

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
      AdminDashboardData.clear_problem_message(APP_NOT_APPROVED) if AdminDashboardData.problem_message_check(APP_NOT_APPROVED)

      connection = Faraday.new(url: 'https://login.salesforce.com')
      response = connection.post("/services/oauth2/token") do |req|
        req.body = URI.encode_www_form({
          grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          assertion: JWT.encode(claims, private_key, 'RS256')
        })
      end

      status = response.status
      body = response.body

      AdminDashboardData.add_problem_message(APP_NOT_APPROVED) if status == 400 && body.include?("user hasn't approved this consumer")
      raise Salesforce::InvalidCredentials if status != 200

      data = JSON.parse(body)
      SiteSetting.salesforce_access_token = data["access_token"]
      SiteSetting.salesforce_instance_url = data["instance_url"]
    end
  
    private
  
    def claims
      {
        iss: SiteSetting.salesforce_client_id,
        sub: SiteSetting.salesforce_username,
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
