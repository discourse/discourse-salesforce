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
  end
end
