# frozen_string_literal: true

module Hubspot
  class RateLimitExceeded < InvalidApiResponse
    attr_reader :retry_after

    def initialize(retry_after: 10)
      @retry_after = [retry_after.to_i, 1].max
      super("HubSpot rate limit reached", status: 429)
    end
  end
end
