# frozen_string_literal: true

module Hubspot
  class InvalidPropertyValue < StandardError
    attr_reader :property

    def sync_activity_diagnostics
      details = { codes: ["INVALID_OPTION"] }
      details[:properties] = [property] if property.is_a?(String) &&
        property.match?(/\A[\w.-]{1,100}\z/)
      details
    end

    def initialize(property)
      @property = property
      super("Invalid option for HubSpot property #{property}")
    end
  end
end
