# frozen_string_literal: true

module Hubspot
  class InvalidPropertyValue < StandardError
    attr_reader :property

    def initialize(property)
      @property = property
      super("Invalid option for HubSpot property #{property}")
    end
  end
end
