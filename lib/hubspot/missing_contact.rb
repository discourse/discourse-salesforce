# frozen_string_literal: true

module Hubspot
  class MissingContact < InvalidApiResponse
    def initialize
      super(
        "Linked contact is unavailable. Restore it or create a replacement with the user's email in HubSpot, then retry sync.",
        status: 404,
      )
    end
  end
end
