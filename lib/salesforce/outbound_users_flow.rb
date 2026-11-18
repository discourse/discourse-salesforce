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

    def self.permanent_sync_errors
      %w[Discourse::InvalidParameters Salesforce::AmbiguousEmailMatch]
    end

    def self.configuration_job
      Jobs::DiscourseCrm::SyncOutboundConfiguration
    end

    def self.batch_job
      Jobs::SyncSalesforceUserBatch
    end

    def self.user_job
      Jobs::SyncSalesforceUser
    end
  end
end
