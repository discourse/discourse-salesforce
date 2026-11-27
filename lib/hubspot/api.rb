# frozen_string_literal: true

require "json"
require "digest"

module ::Hubspot
  class Api
    BASE_URL = "https://api.hubapi.com"
    PREFIX = "/crm/v3"
    PAGE_SIZE = 100
    LAST_MODIFIED_PROPERTY = "lastmodifieddate"
    HIDDEN_PROPERTY_PREFIXES = %w[hs_v2_ hs_analytics_ hs_email_ hs_sequences_].freeze
    OBJECT_PATHS = { "contact" => "contacts", "company" => "companies" }.freeze
    COMPANY_PROPERTY = "associatedcompanyid"
    MISSING_RECORD_CATEGORY = "OBJECT_NOT_FOUND"

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

    def list_contacts(properties:, after: nil, limit: PAGE_SIZE)
      query = { limit: limit, properties: properties.join(",") }
      query[:after] = after if after
      get("objects/contacts", query)
    end

    def search_contacts_modified_since(since, properties:, after: nil, limit: PAGE_SIZE)
      body = {
        filterGroups: [
          {
            filters: [
              {
                propertyName: LAST_MODIFIED_PROPERTY,
                operator: "GTE",
                value: (since.to_f * 1000).to_i.to_s,
              },
            ],
          },
        ],
        sorts: [{ propertyName: LAST_MODIFIED_PROPERTY, direction: "ASCENDING" }],
        properties: properties,
        limit: limit,
      }
      body[:after] = after if after
      post("objects/contacts/search", body)
    end

    def batch_read_contacts_by_email(emails, properties:, &on_validation_error)
      batch_read_contacts(
        emails,
        properties: properties,
        id_property: "email",
        &on_validation_error
      )
    end

    def batch_read_contacts(ids, properties:, id_property: nil)
      ids
        .each_slice(PAGE_SIZE)
        .flat_map do |slice|
          body = { inputs: slice.map { |id| { id: id } }, properties: properties }
          body[:idProperty] = id_property if id_property
          response =
            begin
              post("objects/contacts/batch/read", body)
            rescue InvalidApiResponse => error
              raise unless missing_record_response?(error)
              { "results" => [] }
            end
          unless completed_batch_read?(response)
            raise InvalidApiResponse.new("Invalid contact batch read response")
          end
          errors =
            Array(response["errors"]).reject do |item|
              item.is_a?(Hash) && item["category"] == MISSING_RECORD_CATEGORY
            end
          unless errors.all? { |item| item.is_a?(Hash) && item["category"] == "VALIDATION_ERROR" }
            raise InvalidApiResponse.new("Invalid contact batch read response")
          end
          errors.each do |item|
            error = ApiValidationError.new(item.to_json)
            raise error unless block_given?
            yield error
          end
          response.fetch("results")
        end
    end

    def batch_read_companies(ids, properties:)
      results = []
      missing = []
      ids.each_slice(PAGE_SIZE) do |slice|
        response =
          post(
            "objects/companies/batch/read",
            { inputs: slice.map { |id| { id: id } }, properties: properties },
          )
        unless completed_batch_read?(response)
          raise InvalidApiResponse.new("Incomplete company batch read response")
        end
        results.concat(response.fetch("results"))
        errors, missing_errors =
          Array(response["errors"]).partition { |item| item["category"] != MISSING_RECORD_CATEGORY }
        if errors.any?
          error = errors.find { |item| item["category"] != "VALIDATION_ERROR" } || errors.first
          raise Hubspot::InvalidApiResponse.new(error.to_json, status: 207)
        end
        missing_errors.each { |item| missing.concat(Array(item.dig("context", "ids")).map(&:to_s)) }
      end
      [results, missing]
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

    def self.cached_properties(object, refresh: false)
      new.cached_properties(object, refresh: refresh)
    end

    def cached_properties(object, refresh: false)
      property_metadata(object, refresh: refresh).filter_map do |property|
        name = property.fetch("name")
        next if HIDDEN_PROPERTY_PREFIXES.any? { |prefix| name.start_with?(prefix) }
        {
          name: name,
          label: property["label"],
          type: property["type"],
          group: property["groupName"],
          options: option_labels(property),
        }
      end
    end

    def option_labels(property)
      Array(property["options"]).to_h { |option| [option["value"].to_s, option["label"].to_s] }
    end

    def cached_writable_fields(object, refresh: false)
      raise Discourse::InvalidParameters.new(:object) unless object == "contact"
      writable_fields(property_metadata(object, refresh: refresh))
    end

    private

    def completed_batch_read?(response)
      unless response.is_a?(Hash) && response["results"].is_a?(Array) &&
               [nil, "COMPLETE", "COMPLETED"].include?(response["status"])
        return false
      end
      errors = response.fetch("errors", [])
      errors.is_a?(Array) && errors.all?(Hash) &&
        response.fetch("numErrors", errors.size) == errors.size
    end

    def missing_record_response?(error)
      return false unless error.status == 404
      body = JSON.parse(error.message)
      body.is_a?(Hash) && body["category"] == MISSING_RECORD_CATEGORY
    rescue JSON::ParserError
      false
    end

    def verify_account!
      cache_key =
        "hubspot:token_info:v2:#{RailsMultisite::ConnectionManagement.current_db}:#{@token_fingerprint}"
      info = Rails.cache.read(cache_key)
      unless info
        DistributedMutex.synchronize("hubspot_token_info_#{@token_fingerprint}") do
          info =
            Rails
              .cache
              .fetch(cache_key, expires_in: 1.hour) do
                response =
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
                unless response.is_a?(Hash) && response["hubId"].to_s.match?(/\A[1-9]\d*\z/)
                  raise InvalidCredentials
                end
                response
              end
        end
      end
      unless info.is_a?(Hash) && info["hubId"].present? && info["hubId"].to_s == account
        raise InvalidCredentials
      end
      app = info["appId"].presence || @token_fingerprint
      @rate_limit_key = "hubspot_api:#{account}:#{app}"
    end

    def check_cooldown!
      cooldown = Discourse.redis.without_namespace.ttl("#{@rate_limit_key}:cooldown")
      raise RateLimited.new(retry_after: cooldown) if cooldown > 0
    end

    def throttle!
      RateLimiter.new(nil, @rate_limit_key, 90, 10, global: true).performed!
    rescue RateLimiter::LimitExceeded => error
      raise RateLimited.new(retry_after: error.available_in)
    end

    def property_metadata(object, refresh: false)
      connection = [
        RailsMultisite::ConnectionManagement.current_db,
        account,
        @token_fingerprint,
      ].join(":")
      key = "hubspot:#{object}_properties:v2:#{Digest::SHA256.hexdigest(connection)}"
      Rails.cache.delete(key) if refresh
      Rails
        .cache
        .fetch(key, expires_in: 2.hours) do
          get("properties/#{OBJECT_PATHS.fetch(object)}").fetch("results")
        end
    end

    def writable_fields(properties)
      properties.filter_map do |field|
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
        result = {
          "name" => field.fetch("name"),
          "label" => field["label"].presence || field.fetch("name"),
          "type" => type,
          "custom" => field["hubspotDefined"] == false,
          "createable" => true,
          "updateable" => true,
        }
        if %w[picklist multipicklist].include?(type) && field["options"].is_a?(Array) &&
             !field["externalOptions"]
          result["options"] = field["options"].map { |option| option.fetch("value") }
        end
        result
      end
    end

    def call(path, absolute: false, throttle: true, allow_not_found: false)
      check_cooldown!
      throttle! if throttle
      uri = absolute ? path : File.join(PREFIX, path)
      response = yield(uri)

      case response.status
      when 200, 201, 207
        JSON.parse(response.body)
      when 204
        nil
      when 401
        raise Hubspot::InvalidCredentials
      when 404
        return nil if allow_not_found
        raise_response_error(response)
      when 429
        policy =
          begin
            JSON.parse(response.body)
          rescue JSON::ParserError, TypeError
            nil
          end
        raise DailyQuotaExceeded if policy.is_a?(Hash) && policy["policyName"] == "DAILY"
        retry_after = Integer(response.headers["retry-after"].to_s, exception: false) || 10
        error = RateLimited.new(retry_after: retry_after)
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
      error =
        Hubspot::InvalidApiResponse.from_response(
          response.body.presence || "",
          status: response.status,
        )
      error.set_backtrace(caller)
      DiscourseCrm::ConnectionError.log(error, operation: "api", provider: "hubspot")
      raise error
    end
  end
end
