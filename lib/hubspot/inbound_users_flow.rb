# frozen_string_literal: true

module ::Hubspot
  class InboundUsersFlow
    def self.direction
      "inbound"
    end

    def self.kind
      "users"
    end

    def self.objects
      %w[contact]
    end

    def self.requires_groups?
      false
    end

    def self.validate_mappings!(configuration)
      sources = configuration.mappings.map { |mapping| mapping["source"] }
      unless sources.all? { |source| source.is_a?(String) && source.present? } &&
               sources.uniq.size == sources.size
        raise Discourse::InvalidParameters.new(:mappings)
      end
      available = Api.cached_properties(refresh: true).map { |property| property[:name] }
      raise Discourse::InvalidParameters.new(:mappings) if (sources - available).any?
    end

    def self.configuration_job
      :sync_hubspot_configuration
    end

    def self.user_job
      :sync_hubspot_user
    end
  end
end
