# frozen_string_literal: true

module ::Salesforce
  class OutboundUsersFlow
    def self.direction
      "outbound"
    end

    def self.kind
      "users"
    end

    def self.objects
      %w[Lead Contact]
    end

    def self.requires_groups?
      true
    end

    def self.validate_mappings!(configuration)
      ConfiguredUserSync.validate_mappings!(
        configuration,
        Api.cached_writable_fields(configuration.object, refresh: true),
      )
    end

    def self.configuration_job
      :sync_salesforce_configuration
    end

    def self.user_job
      :sync_salesforce_user
    end
  end
end
