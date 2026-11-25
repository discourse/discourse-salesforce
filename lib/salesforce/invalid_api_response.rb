# frozen_string_literal: true

module ::Salesforce
  class InvalidApiResponse < ::StandardError
    attr_reader :status

    def sync_activity_diagnostics
      body = JSON.parse(message)
      items = body.is_a?(Array) ? body : [body]
      codes =
        items.filter_map do |item|
          next unless item.is_a?(Hash)
          code = item["errorCode"] || item["statusCode"]
          code if code.is_a?(String) && code.match?(/\A[A-Z][A-Z0-9_]{0,99}\z/)
        end
      { codes: codes.uniq.first(20) }
    rescue JSON::ParserError
      {}
    end

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end
  end
end
