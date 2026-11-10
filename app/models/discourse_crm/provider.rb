# frozen_string_literal: true

module DiscourseCrm
  class Provider
    NAMES = %w[salesforce hubspot].freeze

    def self.available_targets
      NAMES.flat_map do |name|
        provider = new(name)
        next [] unless provider.configured?
        provider.objects.map { |object| { provider: name, object: object } }
      end
    end

    def initialize(name)
      raise Discourse::InvalidParameters.new(:provider) if NAMES.exclude?(name)
      @name = name
    end

    def enabled?
      @name == "hubspot" ? SiteSetting.hubspot_enabled : SiteSetting.salesforce_enabled
    end

    def configured?
      enabled? && api_class.has_credentials?
    end

    def objects
      @name == "hubspot" ? %w[Contact] : %w[Lead Contact]
    end

    def account
      @name == "hubspot" ? SiteSetting.hubspot_portal_id : SiteSetting.salesforce_instance_url
    end

    def api_class
      @name == "hubspot" ? Hubspot::Api : Salesforce::Api
    end

    def sync_class
      @name == "hubspot" ? Hubspot::ConfiguredUserSync : Salesforce::ConfiguredUserSync
    end
  end
end
