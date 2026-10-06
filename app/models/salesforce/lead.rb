# frozen_string_literal: true

module ::Salesforce
  class Lead < Person
    ID_FIELD = "salesforce_lead_id"
    DEFAULT_COMPANY_NAME = "None"
    OBJECT_NAME = "Lead"

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
  end
end
