# frozen_string_literal: true

module ::Salesforce
  class Person
    LEAD_ID_FIELD = "salesforce_lead_id".freeze
    CONTACT_ID_FIELD = "salesforce_contact_id".freeze
    DEFAULT_COMPANY_NAME = "None".freeze
    LEAD_SOURCE = "Web".freeze

    def self.create!(type, user)
      id_field = nil
      name = user.name || user.username

      if name.include?(" ")
        first_name, last_name = name.split(" ", 2)
      else
        last_name = name
      end

      payload = {
        Email: user.email,
        LastName: last_name,
        LeadSource: LEAD_SOURCE
      }

      payload.merge!(FirstName: first_name) if first_name.present?

      if type == "lead"
        id_field = LEAD_ID_FIELD
        payload.merge!(Company: DEFAULT_COMPANY_NAME, Website: user.user_profile&.website)
      elsif type == "contact"
        id_field = CONTACT_ID_FIELD
      end

      return if user.custom_fields[id_field].present?

      data = Salesforce::Api.new.post("sobjects/#{type.capitalize}", payload)

      user.custom_fields[id_field] = data["id"]
      user.save_custom_fields
    end
  end
end
