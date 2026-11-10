# frozen_string_literal: true

require "json"
require "digest"

module ::Hubspot
  class Api
    BASE_URL = "https://api.hubapi.com"
    PREFIX = "/crm/v3"

    attr_reader :faraday, :account

    def self.has_credentials?
      SiteSetting.hubspot_portal_id.present? && SiteSetting.hubspot_access_token.present?
    end

    def initialize
      raise Hubspot::InvalidCredentials if !self.class.has_credentials?

      @account = SiteSetting.hubspot_portal_id
      @access_token = SiteSetting.hubspot_access_token
      @token_fingerprint = Digest::SHA256.hexdigest(@access_token)
      @rate_limit_key = "hubspot_api:#{@account}:#{@token_fingerprint}"
      @faraday =
        Faraday.new(
          url: BASE_URL,
          headers: {
            "Authorization" => "Bearer #{@access_token}",
          },
        ) do |builder|
          builder.options.timeout = 30
          builder.options.open_timeout = 10
          builder.adapter FinalDestination::FaradayAdapter
        end
      verify_account!
    end

    def ping
      get("objects/contacts", limit: 1)
    end

    def get(path, query = {}, allow_not_found: false, **query_params)
      call(path, allow_not_found: allow_not_found) do |uri|
        faraday.get(uri, query.merge(query_params))
      end
    end

    def post(path, fields)
      call(path) { |uri| faraday.post(uri, fields.to_json, "Content-Type": "application/json") }
    end

    def patch(path, fields)
      call(path) { |uri| faraday.patch(uri, fields.to_json, "Content-Type": "application/json") }
    end

    def self.cached_writable_fields(object, refresh: false)
      new.cached_writable_fields(object, refresh: refresh)
    end

    def cached_writable_fields(object, refresh: false)
      raise Discourse::InvalidParameters.new(:object) unless object == "Contact"
      connection = [
        RailsMultisite::ConnectionManagement.current_db,
        account,
        @token_fingerprint,
      ].join(":")
      key = "hubspot:writable_fields:v2:#{Digest::SHA256.hexdigest(connection)}"
      Rails.cache.delete(key) if refresh
      Rails.cache.fetch(key, expires_in: 2.hours) { writable_fields }
    end

    private

    def verify_account!
      cache_key =
        "hubspot:token_info:v1:#{RailsMultisite::ConnectionManagement.current_db}:#{@token_fingerprint}"
      info = Rails.cache.read(cache_key)
      unless info
        DistributedMutex.synchronize("hubspot_token_info_#{@token_fingerprint}") do
          info =
            Rails
              .cache
              .fetch(cache_key, expires_in: 1.hour) do
                call(
                  "/oauth/v2/private-apps/get/access-token-info",
                  absolute: true,
                  throttle: false,
                ) do |uri|
                  faraday.post(
                    uri,
                    { tokenKey: @access_token }.to_json,
                    "Content-Type": "application/json",
                  )
                end
              end
        end
      end
      unless info.is_a?(Hash) && info["hubId"].present? && info["hubId"].to_s == account
        raise InvalidCredentials
      end
      app = info["appId"].presence || @token_fingerprint
      @rate_limit_key = "hubspot_api:#{account}:#{app}"
    end

    def throttle!
      cooldown = Discourse.redis.without_namespace.ttl("#{@rate_limit_key}:cooldown")
      raise RateLimitExceeded.new(retry_after: cooldown) if cooldown > 0
      RateLimiter.new(nil, @rate_limit_key, 90, 10, global: true).performed!
    rescue RateLimiter::LimitExceeded => error
      raise RateLimitExceeded.new(retry_after: error.available_in)
    end

    def writable_fields
      get("properties/contacts")
        .fetch("results")
        .filter_map do |field|
          if field["archived"] || field["calculated"] ||
               field.dig("modificationMetadata", "readOnlyValue")
            next
          end
          type =
            case field["type"]
            when "string"
              "string"
            when "number"
              "double"
            when "bool"
              "boolean"
            when "date", "datetime"
              field["type"]
            when "enumeration"
              case field["fieldType"]
              when "booleancheckbox"
                "boolean"
              when "checkbox"
                "multipicklist"
              else
                "picklist"
              end
            end
          next unless type
          {
            "name" => field.fetch("name"),
            "label" => field.fetch("label"),
            "type" => type,
            "custom" => field["hubspotDefined"] == false,
            "createable" => true,
            "updateable" => true,
          }
        end
    end

    def call(path, absolute: false, throttle: true, allow_not_found: false)
      throttle! if throttle
      uri = absolute ? path : File.join(PREFIX, path)
      response = yield(uri)

      case response.status
      when 200, 201
        JSON.parse(response.body)
      when 204
        nil
      when 401
        raise Hubspot::InvalidCredentials
      when 404
        return nil if allow_not_found
        raise_response_error(response)
      when 429
        retry_after = Integer(response.headers["retry-after"].to_s, exception: false) || 10
        error = RateLimitExceeded.new(retry_after: retry_after)
        Discourse.redis.without_namespace.setex(
          "#{@rate_limit_key}:cooldown",
          error.retry_after,
          "1",
        )
        raise error
      else
        raise_response_error(response)
      end
    end

    def raise_response_error(response)
      error = Hubspot::InvalidApiResponse.new(response.body.presence || "", status: response.status)
      error.set_backtrace(caller)
      DiscourseCrm::ConnectionError.log(error, operation: "api", provider: "hubspot")
      raise error
    end
  end
end
