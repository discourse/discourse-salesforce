# frozen_string_literal: true

module DiscourseCrm
  class InvalidDestinationValue < StandardError
    attr_reader :destinations

    def initialize(destinations)
      @destinations = destinations
      super("Discourse rejected CRM values for #{destinations.join(", ")}")
    end

    def sync_activity_diagnostics
      { destinations: }
    end
  end
end
