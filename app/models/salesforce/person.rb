# frozen_string_literal: true

module ::Salesforce
  class Person
    LEAD_ID_FIELD = "salesforce_lead_id".freeze
    CONTACT_ID_FIELD = "salesforce_contact_id".freeze
    DEFAULT_COMPANY_NAME = "None".freeze
    SOURCE = "Web".freeze

    def self.create!(type, user)
      id_field = nil
      payload = nil

      if type == "lead"
        id_field = LEAD_ID_FIELD
        payload = user.salesforce_lead_payload
      elsif type == "contact"
        id_field = CONTACT_ID_FIELD
        payload = user.salesforce_contact_payload
      end

      return if user.custom_fields[id_field].present?

      data = Salesforce::Api.new.post("sobjects/#{type.capitalize}", payload)
      id = data["id"]

      user.custom_fields[id_field] = id
      user.save_custom_fields

      if type == "lead"
        Salesforce.leads_group.add(user)
      elsif type == "contact"
        Salesforce.contacts_group.add(user)
      end

      id
    end
  end
end
