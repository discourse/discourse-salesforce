# frozen_string_literal: true

require "json"
require "cgi"
require "digest"

module ::Salesforce
  class Api
    VERSION = "49.0"
    REQUEST_TIMEOUT = 30
    OPEN_TIMEOUT = 10
    WRITABLE_FIELDS_CACHE_TTL = 2.hours
    INVALID_RESPONSE = "salesforce.error.invalid_response"
    ACCESS_TOKEN_KEY = "salesforce_access_token"
    CREDENTIAL_SETTINGS = %i[
      salesforce_authorization_server_url
      salesforce_client_id
      salesforce_rsa_private_key
      salesforce_username
    ].freeze

    attr_reader :faraday, :prefix

    def initialize
      set_access_token

      @faraday =
        Faraday.new(
          url: SiteSetting.salesforce_instance_url,
          headers: {
            "Authorization" => "Bearer #{access_token}",
          },
        ) do |connection|
          connection.options.timeout = REQUEST_TIMEOUT
          connection.options.open_timeout = OPEN_TIMEOUT
        end
      @prefix = "/services/data/v#{VERSION}"
    end

    def writable_fields(object)
      raise Discourse::InvalidParameters.new(:object) if %w[Lead Contact].exclude?(object)

      get("sobjects/#{object}/describe")
        .fetch("fields")
        .filter_map do |field|
          next unless field["createable"] || field["updateable"]
          next if field["calculated"] || field["autoNumber"]

          field.slice("name", "label", "type", "custom", "createable", "updateable")
        end
    end

    def query(soql)
      get("query/?q=#{CGI.escape(soql)}")
    end

    def get(path)
      call(path) { |uri| faraday.get(uri) }
    end

    def post(path, fields)
      call(path) { |uri| faraday.post(uri, fields.to_json, "Content-Type": "application/json") }
    end

    def patch(path, fields, headers: {})
      call(path) do |uri|
        faraday.patch(uri, fields.to_json, { "Content-Type": "application/json" }.merge(headers))
      end
    end

    def call(path)
      uri = File.join(prefix, path)
      response = yield(uri)

      case response.status
      when 200, 201
        JSON.parse response.body
      when 204
        nil
      else
        e =
          ::Salesforce::InvalidApiResponse.new(
            response.body.presence || "",
            status: response.status,
          )
        e.set_backtrace(caller)
        ConnectionError.log(e, operation: "api")
        raise e
      end
    end

    def self.cached_writable_fields(object, refresh: false)
      new.cached_writable_fields(object, refresh: refresh)
    end

    def cached_writable_fields(object, refresh: false)
      connection = [
        RailsMultisite::ConnectionManagement.current_db,
        SiteSetting.salesforce_authorization_server_url,
        SiteSetting.salesforce_client_id,
        SiteSetting.salesforce_username,
        SiteSetting.salesforce_instance_url,
      ].join(":")
      cache_key = "salesforce:writable_fields:v1:#{Digest::SHA256.hexdigest(connection)}:#{object}"
      Rails.cache.delete(cache_key) if refresh
      Rails
        .cache
        .fetch(cache_key, expires_in: WRITABLE_FIELDS_CACHE_TTL) { writable_fields(object) }
    end

    def set_access_token
      if !self.class.has_credentials?
        ProblemCheckTracker[:salesforce_invalid_credentials].problem!
        raise Salesforce::InvalidCredentials
      end

      ProblemCheckTracker[:salesforce_app_not_approved].no_problem!

      return if access_token.present? && SiteSetting.salesforce_instance_url.present?

      connection =
        Faraday.new(url: SiteSetting.salesforce_authorization_server_url) do |faraday|
          faraday.options.timeout = REQUEST_TIMEOUT
          faraday.options.open_timeout = OPEN_TIMEOUT
        end
      response =
        connection.post("/services/oauth2/token") do |req|
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
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
        ProblemCheckTracker[:salesforce_app_not_approved].problem!
      end
      if status >= 300 && SiteSetting.salesforce_api_error_logs
        Rails.logger.error("Salesforce authentication request failed: status=#{status}")
      end

      if status == 429 || status >= 500
        raise Salesforce::InvalidApiResponse.new(
                "Authentication service unavailable",
                status: status,
              )
      end
      if status != 200
        ProblemCheckTracker[:salesforce_invalid_credentials].problem!
        raise Salesforce::InvalidCredentials
      end

      ProblemCheckTracker[:salesforce_invalid_credentials].no_problem!
      data = JSON.parse(body)
      Discourse.redis.setex(ACCESS_TOKEN_KEY, 10.minutes, data["access_token"])
      SiteSetting.salesforce_instance_url = data["instance_url"]
    end

    def access_token
      Discourse.redis.get(ACCESS_TOKEN_KEY)
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

    def self.reset_access_token_cache!
      Discourse.redis.del(ACCESS_TOKEN_KEY)
    end
  end
end
