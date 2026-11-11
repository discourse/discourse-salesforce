# frozen_string_literal: true

module ::Hubspot
  class SyncProvider
    def self.key
      "hubspot"
    end

    def self.account
      SiteSetting.hubspot_portal_id
    end

    def self.enabled?
      SiteSetting.salesforce_enabled && SiteSetting.hubspot_enabled &&
        SiteSetting.enable_guided_sync_configuration
    end

    def self.credentials?
      Api.has_credentials?
    end

    def self.flows
      [InboundUsersFlow]
    end

    def self.flow(direction, kind)
      flows.find { |flow| flow.direction == direction && flow.kind == kind }
    end
  end
end
