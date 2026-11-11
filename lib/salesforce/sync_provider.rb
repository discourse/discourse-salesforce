# frozen_string_literal: true

module ::Salesforce
  class SyncProvider
    def self.key
      "salesforce"
    end

    def self.account
      SiteSetting.salesforce_instance_url
    end

    def self.enabled?
      SiteSetting.salesforce_enabled && SiteSetting.enable_guided_sync_configuration
    end

    def self.credentials?
      Api.has_credentials?
    end

    def self.flows
      [OutboundUsersFlow]
    end

    def self.flow(direction, kind)
      flows.find { |flow| flow.direction == direction && flow.kind == kind }
    end
  end
end
