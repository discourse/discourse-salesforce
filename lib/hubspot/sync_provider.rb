# frozen_string_literal: true

module ::Hubspot
  class SyncProvider
    OBJECT_TYPE_IDS = { "contact" => "0-1", "company" => "0-2" }.freeze

    def self.key
      "hubspot"
    end

    def self.icon
      "fab-hubspot"
    end

    def self.record_url(record)
      "https://app.hubspot.com/contacts/#{record.account}/record/#{OBJECT_TYPE_IDS.fetch(record.object)}/#{record.external_id}"
    end

    def self.failure_reason_class
      FailureReason
    end

    def self.account
      SiteSetting.hubspot_portal_id
    end

    def self.enabled?
      SiteSetting.hubspot_enabled && SiteSetting.enable_guided_sync_configuration
    end

    def self.credentials?
      Api.has_credentials?
    end

    def self.flows
      [InboundUsersFlow, OutboundUsersFlow]
    end

    def self.flow(direction, kind)
      flows.find { |flow| flow.direction == direction && flow.kind == kind }
    end
  end
end
