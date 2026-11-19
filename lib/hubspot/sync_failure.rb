# frozen_string_literal: true

module Hubspot
  class SyncFailure
    def self.retryable?(error)
      if error.is_a?(Discourse::InvalidParameters) || error.is_a?(InvalidPropertyValue) ||
           error.is_a?(InvalidCredentials)
        return false
      end
      return error.retryable? if error.is_a?(InvalidApiResponse)
      true
    end

    def self.record(configuration_id, user_id, error)
      if error.instance_of?(InvalidApiResponse)
        error = InvalidApiResponse.from_response(error.message, status: error.status)
      end
      DiscourseCrm::SyncConfiguration.record_result(configuration_id, user_id, error: error)
      if error.is_a?(InvalidPropertyValue)
        Rails.logger.warn(
          "HubSpot mapping rejected: configuration_id=#{configuration_id} user_id=#{user_id} property=#{error.property.to_json}",
        )
      end
    end
  end
end
