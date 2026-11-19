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
      body = JSON.parse(message.to_s)
      return {} unless body.is_a?(Hash)
      details = [body, *Array(body["errors"])].select { |item| item.is_a?(Hash) }
      {
        category: body["category"],
        correlation_id: body["correlationId"],
        codes: details.map { |item| item["code"] },
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
  end
end
