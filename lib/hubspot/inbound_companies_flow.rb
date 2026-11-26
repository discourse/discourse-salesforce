# frozen_string_literal: true

module ::Hubspot
  # Pulls the companies that contacts pulled into Discourse point to. Companies reach users
  # only through those contacts, so they cannot fill Discourse fields.
  class InboundCompaniesFlow
    def self.direction
      "inbound"
    end

    def self.kind
      "companies"
    end

    def self.objects
      %w[company]
    end

    def self.requires_groups?
      false
    end

    def self.validate_mappings!(configuration)
      DiscourseCrm::PullMappings.validate!(
        configuration,
        InboundUsersFlow.pull_fields("company", refresh: true),
        copies_to_discourse: false,
      )
    end

    def self.configuration_job
      Jobs::Hubspot::PullCompanies
    end

    # Nothing else owns company records, so they go with the pull that stored them.
    def self.removed(configuration)
      DiscourseCrm::Record.within(
        provider: configuration.provider,
        account: configuration.account,
        object: configuration.object,
      ).delete_all
    end

    # Companies are not matched to users, so user changes start no company pull.
    def self.user_job
      nil
    end
  end
end
