# frozen_string_literal: true

module DiscourseCrm
  class ConnectionError
    def self.category(error)
      if error.is_a?(Salesforce::InvalidCredentials) ||
           error.is_a?(::Hubspot::InvalidCredentials) || error.is_a?(OpenSSL::PKey::RSAError)
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

    def self.log(error, operation:, provider: "salesforce")
      status = error.respond_to?(:status) ? error.status : nil
      label = provider == "hubspot" ? "HubSpot" : "Salesforce"
      diagnostics = error.respond_to?(:diagnostics) ? error.diagnostics : {}
      suffix = diagnostics.present? ? " details=#{diagnostics.to_json}" : ""
      Rails.logger.warn(
        "#{label} request failed: operation=#{operation} category=#{category(error)} status=#{status || "unknown"}#{suffix}",
      )
    end
  end
end
