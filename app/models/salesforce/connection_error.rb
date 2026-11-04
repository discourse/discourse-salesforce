# frozen_string_literal: true

module Salesforce
  class ConnectionError
    def self.category(error)
      if error.is_a?(InvalidCredentials) || error.is_a?(OpenSSL::PKey::RSAError)
        return "authentication"
      end
      return "temporary" if error.is_a?(Faraday::Error)
      case error.status
      when 401
        "authentication"
      when 403
        "permissions"
      when 429
        "rate_limit"
      when 500..599
        "temporary"
      else
        "invalid_response"
      end
    end

    def self.log(error, operation:)
      status = error.respond_to?(:status) ? error.status : nil
      Rails.logger.warn(
        "Salesforce request failed: operation=#{operation} category=#{category(error)} status=#{status || "unknown"}",
      )
    end
  end
end
