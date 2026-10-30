# frozen_string_literal: true

module ::Salesforce
  class Lead < Person
    ID_FIELD = "salesforce_lead_id"
    DEFAULT_COMPANY_NAME = "None"
    OBJECT_NAME = "Lead"
    REQUIRED_MAPPING_FIELDS = %w[LastName Company].freeze

    def self.create!(user)
      return unless Salesforce.leads_enabled?

      Salesforce.seed_groups! if group.blank?
      super
    end

    def self.group
      Salesforce.leads_group
    end

    def self.payload(user)
      user.salesforce_lead_payload
    end

    def self.find_converted_by_email(email, api: Salesforce.api)
      escaped_email = escape_soql_string(email)
      result =
        api.query(
          "SELECT Id, IsConverted, ConvertedContactId FROM Lead WHERE Email = '#{escaped_email}' AND IsConverted = true",
        )
      return if result["totalSize"] == 0
      raise AmbiguousEmailMatch.new(OBJECT_NAME) if result["totalSize"] > 1

      result.fetch("records").first
    end
  end
end
