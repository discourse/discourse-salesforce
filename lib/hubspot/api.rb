# frozen_string_literal: true

require "json"

module ::Hubspot
  class Api
    BASE_URL = "https://api.hubapi.com"
    PREFIX = "/crm/v3"
    REQUEST_TIMEOUT = 30
    OPEN_TIMEOUT = 10
    PAGE_SIZE = 100
    PROPERTIES_CACHE_TTL = 2.hours
    HIDDEN_PROPERTY_PREFIXES = %w[hs_v2_ hs_analytics_ hs_email_ hs_sequences_].freeze
    LAST_MODIFIED_PROPERTY = "lastmodifieddate"
    INVALID_RESPONSE = "hubspot.error.invalid_response"

    attr_reader :faraday

    def self.has_credentials?
      SiteSetting.hubspot_portal_id.present? && SiteSetting.hubspot_access_token.present?
    end

    def self.cached_properties(refresh: false)
      new.cached_properties(refresh: refresh)
    end

    def initialize
      raise Hubspot::InvalidCredentials if !self.class.has_credentials?

      @faraday =
        Faraday.new(
          url: BASE_URL,
          headers: {
            "Authorization" => "Bearer #{SiteSetting.hubspot_access_token}",
          },
        ) do |builder|
          builder.adapter FinalDestination::FaradayAdapter
          builder.options.timeout = REQUEST_TIMEOUT
          builder.options.open_timeout = OPEN_TIMEOUT
        end
    end

    def account
      SiteSetting.hubspot_portal_id
    end

    def ping
      get("objects/contacts", limit: 1)
    end

    def properties
      get("properties/contacts")
        .fetch("results")
        .filter_map do |property|
          name = property["name"].to_s
          next if HIDDEN_PROPERTY_PREFIXES.any? { |prefix| name.start_with?(prefix) }
          {
            name: name,
            label: property["label"],
            type: property["type"],
            group: property["groupName"],
          }
        end
    end

    def cached_properties(refresh: false)
      connection = [RailsMultisite::ConnectionManagement.current_db, account].join(":")
      cache_key = "hubspot:contact_properties:v1:#{Digest::SHA256.hexdigest(connection)}"
      Rails.cache.delete(cache_key) if refresh
      Rails.cache.fetch(cache_key, expires_in: PROPERTIES_CACHE_TTL) { properties }
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

    def batch_read_contacts_by_email(emails, properties:)
      emails
        .each_slice(PAGE_SIZE)
        .flat_map do |slice|
          post(
            "objects/contacts/batch/read",
            {
              idProperty: "email",
              inputs: slice.map { |email| { id: email } },
              properties: properties,
            },
          ).fetch("results")
        end
    end

    def get(path, query = {})
      call(path) { |uri| faraday.get(uri, query) }
    end

    def post(path, body)
      call(path) { |uri| faraday.post(uri, body.to_json, "Content-Type" => "application/json") }
    end

    private

    def call(path)
      uri = File.join(PREFIX, path)
      response = yield(uri)

      case response.status
      when 200, 201, 207
        JSON.parse(response.body)
      when 204
        nil
      when 401
        raise Hubspot::InvalidCredentials
      when 429
        retry_after = response.headers["Retry-After"].to_i
        raise Hubspot::RateLimited.new(
                response.body.presence || "",
                retry_after: retry_after.positive? ? retry_after : nil,
              )
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
