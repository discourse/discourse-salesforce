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
      mappings = configuration.mappings
      unless mappings.all? { |mapping|
               Api::OBJECT_PATHS.key?(mapping["object"]) && mapping["source"].is_a?(String) &&
                 mapping["source"].present?
             }
        raise Discourse::InvalidParameters.new(:mappings)
      end
      mappings
        .group_by { |mapping| mapping["object"] }
        .each do |object, group|
          sources = group.map { |mapping| mapping["source"] }
          raise Discourse::InvalidParameters.new(:mappings) if sources.uniq.size != sources.size
          available =
            Api.cached_properties(object, refresh: true).map { |property| property[:name] }
          raise Discourse::InvalidParameters.new(:mappings) if (sources - available).any?
        end
    end

    def self.property_labels(object)
      Api.cached_properties(object).to_h { |property| [property[:name], property[:label]] }
    end

    def self.configuration_job
      Jobs::Hubspot::SyncConfiguration
    end

    def self.user_job
      Jobs::Hubspot::SyncUser
    end
  end
end
