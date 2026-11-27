# frozen_string_literal: true

module ::Hubspot
  class InboundUsersFlow
    # Discourse keeps a single name, so pulls can read HubSpot's first and last name as one field.
    # "+" cannot appear in HubSpot property names, so this never collides with a real property.
    FULL_NAME = "firstname+lastname"
    FULL_NAME_PARTS = %w[firstname lastname].freeze

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
      DiscourseCrm::PullMappings.validate!(
        configuration,
        pull_fields(configuration.object, refresh: true),
      )
    end

    # HubSpot properties with the generic type pulls use. Contacts also get the full name.
    def self.pull_fields(object, api: Api.new, refresh: false)
      properties = api.cached_properties(object, refresh: refresh)
      if object == "contact" && (FULL_NAME_PARTS - properties.pluck(:name)).empty?
        full_name = {
          name: FULL_NAME,
          label: I18n.t("hubspot.full_name_property"),
          type: "string",
          group: "contactinformation",
        }
        properties = [full_name, *properties]
      end
      properties.map { |property| property.merge(source_type: source_type(property)) }
    end

    # The HubSpot properties a mapping source reads.
    def self.source_fields(source)
      source == FULL_NAME ? FULL_NAME_PARTS : [source]
    end

    def self.with_full_name(properties)
      full_name = FULL_NAME_PARTS.map { |part| properties[part] }.compact_blank.join(" ")
      properties.merge(FULL_NAME => full_name.presence)
    end

    def self.source_type(property)
      case property[:type]
      when "number"
        "number"
      when "date", "datetime"
        "date"
      when "bool"
        "boolean"
      else
        "text"
      end
    end
    private_class_method :source_type

    # Labels for the properties a contact or company pull stores, including the full name.
    def self.property_labels(object)
      pull_fields(object).to_h { |property| [property[:name], property[:label]] }
    end

    def self.configuration_job
      Jobs::Hubspot::SyncConfiguration
    end

    def self.user_job
      Jobs::DiscourseCrm::PullUser
    end

    def self.importer
      ContactImport
    end

    # Companies reach users only through contacts, so removed contacts can orphan them.
    def self.records_removed(configuration)
      CompanyImport.remove_unreferenced(configuration.account)
    end

    # Errors a retry cannot fix, so the user's pull stops until something changes.
    def self.stops_pull?(error)
      [Discourse::InvalidParameters, ApiValidationError, DailyQuotaExceeded].any? do |stop|
        error.is_a?(stop)
      end
    end
  end
end
