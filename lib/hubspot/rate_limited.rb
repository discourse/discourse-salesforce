# frozen_string_literal: true

module ::Hubspot
  class RateLimited < InvalidApiResponse
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil)
      super(message, status: 429)
      @retry_after = retry_after
    end
  end
end
