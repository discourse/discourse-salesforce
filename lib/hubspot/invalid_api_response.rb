# frozen_string_literal: true

require "json"

module ::Hubspot
  class InvalidApiResponse < ::StandardError
    attr_reader :status

    def self.from_response(message, status: nil)
      body =
        begin
          JSON.parse(message.to_s)
        rescue JSON::ParserError
          nil
        end
      if status == 400 && body.is_a?(Hash) && body["category"] == "VALIDATION_ERROR"
        ApiValidationError.new(message, status: status)
      else
        new(message, status: status)
      end
    end

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end

    def retryable?
      status.nil? || [408, 423, 429, 477].include?(status) || status >= 500
    end

    def diagnostics
      local_code =
        {
          "Contact search limit reached without a later modified date" => "CONTACT_SEARCH_LIMIT",
          "Contact batch rejected" => "CONTACT_BATCH_REJECTED",
          "Unexpected company in batch read response" => "UNEXPECTED_COMPANY",
          "Conflicting company IDs in batch read response" => "CONFLICTING_COMPANY_IDS",
          "Incomplete company batch read response" => "INCOMPLETE_COMPANY_BATCH_READ",
          "Invalid contact batch read response" => "INVALID_BATCH_READ_RESPONSE",
          "Invalid contact batch write response" => "INVALID_BATCH_WRITE_RESPONSE",
          "Contact requires individual reconciliation" => "BATCH_RESULT_UNCONFIRMED",
        }[
          message
        ]
      return { codes: [local_code] } if local_code

      body = JSON.parse(message.to_s)
      return {} unless body.is_a?(Hash)
      details = [body, *Array(body["errors"])].select { |item| item.is_a?(Hash) }
      details += details.flat_map { |item| embedded_validation_errors(item["message"]) }
      {
        category: body["category"],
        correlation_id: body["correlationId"],
        codes: details.map { |item| item["code"] || item["error"] },
        properties:
          details.flat_map do |item|
            context = item["context"].is_a?(Hash) ? item["context"] : {}
            [item["name"], *Array(context["propertyName"])]
          end,
      }.transform_values do |value|
          Array(value)
            .select { |item| item.is_a?(String) && item.match?(/\A[\w.-]{1,100}\z/) }
            .uniq
            .first(20)
        end
        .reject { |_, values| values.empty? }
    rescue JSON::ParserError, TypeError
      {}
    end

    def sync_activity_diagnostics
      diagnostics.merge(rejected_email: rejected_email)
    end

    def rejected_email
      body = JSON.parse(message.to_s)
      return unless body.is_a?(Hash)
      details = [body, *Array(body["errors"])].select { |item| item.is_a?(Hash) }
      details += details.flat_map { |item| embedded_validation_errors(item["message"]) }
      details.each do |item|
        next unless (item["code"] || item["error"]) == "INVALID_EMAIL"
        property = item["name"] || Array(item.dig("context", "propertyName")).first
        next unless property == "email"

        value = item["value"]
        if value.nil? && item["message"].is_a?(String)
          value = item["message"][/\AEmail address (.+) is invalid\z/, 1]
        end
        return value if value.is_a?(String) && value.length <= 320 && !value.match?(/[[:cntrl:]]/)
      end
      nil
    rescue JSON::ParserError, TypeError
      nil
    end

    private

    def embedded_validation_errors(message)
      prefix = "Property values were not valid: "
      return [] unless message.is_a?(String) && message.start_with?(prefix)

      # HubSpot embeds JSON validation details inside its human-readable message.
      errors = JSON.parse(message.delete_prefix(prefix))
      return [] unless errors.is_a?(Array)
      errors.select { |item| item.is_a?(Hash) }
    rescue JSON::ParserError
      []
    end
  end
end
