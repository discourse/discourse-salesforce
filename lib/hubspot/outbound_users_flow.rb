# frozen_string_literal: true

module Hubspot
  class OutboundUsersFlow
    def self.direction
      "outbound"
    end

    def self.kind
      "users"
    end

    def self.objects
      %w[contact]
    end

    def self.requires_groups?
      true
    end

    def self.validate_mappings!(configuration)
      ConfiguredUserSync.validate_mappings!(
        configuration,
        Api.new.cached_writable_fields(configuration.object, refresh: true),
      )
    end

    def self.permanent_sync_errors
      %w[
        Discourse::InvalidParameters
        Hubspot::InvalidPropertyValue
        Hubspot::ApiValidationError
        Hubspot::MissingContact
      ]
    end

    def self.configuration_job
      Jobs::DiscourseCrm::SyncOutboundConfiguration
    end

    def self.user_job
      Jobs::Hubspot::PushUser
    end

    def self.batch_job
      Jobs::Hubspot::PushUserBatch
    end
  end
end
