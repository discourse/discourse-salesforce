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
      name = self.name || self.username

      if name.include?(" ")
        first_name, last_name = name.split(" ", 2)
      else
        last_name = name
      end

      payload = {
        Email: self.email,
        LastName: last_name,
        LeadSource: ::Salesforce::Contact::SOURCE,
        Description: "#{Discourse.base_url}/u/#{UrlHelper.encode_component(self.username)}",
      }

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
