# frozen_string_literal: true

module Salesforce
  module UserExtension
    extend ActiveSupport::Concern

    def salesforce_contact_id
      custom_fields[::Salesforce::Contact::ID_FIELD]
    end

    def salesforce_lead_id
      custom_fields[::Salesforce::Lead::ID_FIELD]
    end

    def salesforce_contact_id=(value)
      custom_fields[::Salesforce::Contact::ID_FIELD] = value
    end

    def salesforce_lead_id=(value)
      custom_fields[::Salesforce::Lead::ID_FIELD] = value
    end

    def create_salesforce_contact
      ::Salesforce::Contact.create!(self)
    end

    def salesforce_contact_payload
      first_name, last_name = UserSyncSources.name_parts(self)

      payload = { Email: self.email, LastName: last_name, Description: full_url }

      lead_source = SiteSetting.salesforce_lead_source
      payload[:LeadSource] = lead_source if lead_source.present?
      payload.merge!(FirstName: first_name) if first_name.present?

      payload
    end

    def salesforce_lead_payload
      salesforce_contact_payload.merge(
        { Company: ::Salesforce::Lead::DEFAULT_COMPANY_NAME, Website: self.user_profile&.website },
      )
    end
  end
end
