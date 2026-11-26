# frozen_string_literal: true

module ::Salesforce
  class InboundUsersFlow
    # Salesforce builds the read-only Name from these fields, so pushes into them reach Name.
    NAME_PARTS = %w[FirstName LastName].freeze

    def self.direction
      "inbound"
    end

    def self.kind
      "users"
    end

    def self.objects
      %w[Lead Contact]
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

    # Readable Salesforce fields with the generic type pulls use.
    def self.pull_fields(object, refresh: false)
      Api
        .cached_readable_fields(object, refresh: refresh)
        .map { |field| field.symbolize_keys.merge(source_type: source_type(field)) }
    end

    def self.property_labels(object)
      pull_fields(object).to_h { |field| [field[:name], field[:label]] }
    end

    # The Salesforce fields a mapping source reads.
    def self.source_fields(source)
      source == "Name" ? NAME_PARTS : [source]
    end

    def self.source_type(field)
      type = DiscourseCrm::FieldMapping.field_type(field["type"])
      %w[number date boolean].include?(type) ? type : "text"
    end
    private_class_method :source_type

    def self.configuration_job
      Jobs::PullSalesforceConfiguration
    end

    def self.user_job
      Jobs::DiscourseCrm::PullUser
    end

    def self.importer
      RecordImport
    end

    # Errors a retry cannot fix, so the user's pull stops until something changes. A 400 means
    # Salesforce refused the query itself, for example because a mapped field no longer exists.
    def self.stops_pull?(error)
      case error
      when Discourse::InvalidParameters, InvalidCredentials
        true
      when InvalidApiResponse
        error.status == 400
      else
        false
      end
    end
  end
end
