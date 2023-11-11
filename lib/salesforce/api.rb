# frozen_string_literal: true

require "json"

module ::Salesforce
  class InvalidApiResponse < ::StandardError
  end
  class InvalidCredentials < ::StandardError
  end

  class Api
    VERSION = "49.0"
    INVALID_RESPONSE = "salesforce.error.invalid_response"
    APP_NOT_APPROVED = "dashboard.salesforce.app_not_approved"

    attr_reader :faraday, :prefix

    def initialize
      set_access_token

      @faraday =
        Faraday.new(
          url: SiteSetting.salesforce_instance_url,
          headers: {
            "Authorization" => "Bearer #{access_token}",
          },
        )
      @prefix = "/services/data/v#{VERSION}"
    end

    def query(soql)
      soql = URI::Parser.new.escape(soql.gsub(" ", "+"))
      get("query/?q=#{soql}")
    end

    def get(path)
      call(path) { |uri| faraday.get(uri) }
    end

    def post(path, fields)
      call(path) { |uri| faraday.post(uri, fields.to_json, "Content-Type": "application/json") }
    end

    def call(path)
      uri = File.join(prefix, path)
      response = yield(uri)

      case response.status
      when 200, 201
        JSON.parse response.body
      else
        e = ::Salesforce::InvalidApiResponse.new(response.body.presence || "")
        e.set_backtrace(caller)
        Discourse.warn_exception(e, message: I18n.t(INVALID_RESPONSE), env: { api_uri: uri })
        raise e
      end
    end

    def set_access_token
      raise Salesforce::InvalidCredentials unless self.class.has_credentials?

      if AdminDashboardData.problem_message_check(APP_NOT_APPROVED)
        AdminDashboardData.clear_problem_message(APP_NOT_APPROVED)
      end
      return if access_token.present? && SiteSetting.salesforce_instance_url.present?

      connection = Faraday.new(url: SiteSetting.salesforce_authorization_server_url)
      response =
        connection.post("/services/oauth2/token") do |req|
          req.body =
            URI.encode_www_form(
              {
                grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
                assertion: jwt_assertion,
              },
            )
        end

      status = response.status
      body = response.body

      if status == 400 && body.include?("user hasn't approved this consumer")
        AdminDashboardData.add_problem_message(APP_NOT_APPROVED)
      end
      if status >= 300 && SiteSetting.salesforce_api_error_logs
        Rails.logger.error("Salesforce API error: #{status} #{body}")
      end
      raise Salesforce::InvalidCredentials if status != 200

      data = JSON.parse(body)
      Discourse.redis.setex("salesforce_access_token", 10.minutes, data["access_token"])
      SiteSetting.salesforce_instance_url = data["instance_url"]
    end

    def access_token
      Discourse.redis.get("salesforce_access_token")
    end

    def claims
      {
        iss: SiteSetting.salesforce_client_id,
        sub: SiteSetting.salesforce_username,
        aud: SiteSetting.salesforce_authorization_server_url,
        iat: Time.now.utc.to_i,
        exp: Time.now.utc.to_i + 180,
      }
    end

    def private_key
      OpenSSL::PKey::RSA.new(SiteSetting.salesforce_rsa_private_key)
    end

    def jwt_assertion
      JWT.encode(claims, private_key, "RS256")
    end

    def self.has_credentials?
      SiteSetting.salesforce_client_id.present? && SiteSetting.salesforce_username.present? &&
        SiteSetting.salesforce_rsa_private_key.present? &&
        SiteSetting.salesforce_authorization_server_url.present?
    end
  end
end
