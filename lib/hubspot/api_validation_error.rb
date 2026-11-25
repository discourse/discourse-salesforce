# frozen_string_literal: true

module Hubspot
  class ApiValidationError < InvalidApiResponse
    def retryable?
      false
    end
  end
end
