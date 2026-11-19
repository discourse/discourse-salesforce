# frozen_string_literal: true

module Hubspot
  class DailyQuotaExceeded < InvalidApiResponse
    def initialize
      super("HubSpot daily API quota exhausted", status: 429)
    end

    def retryable?
      false
    end
  end
end
