# frozen_string_literal: true

module ::Salesforce
  class Lead
    ID_FIELD = "salesforce_lead_id".freeze
    DEFAULT_COMPANY_NAME = "None".freeze
    LEAD_SOURCE = "Web".freeze

    def self.create!(user)
      return if user.custom_fields[ID_FIELD].present?

      name = user.name || user.username
      first_name, last_name = (user.name || "").split(" ", 2)
      photo_url = user.uploaded_avatar&.short_path
      photo_url = "#{Discourse.base_url}#{photo_url}" if photo_url.present?

      data = Salesforce::Api.new.post("sobjects/Lead", {
        Email: user.email,
        FirstName: first_name,
        LastName: last_name,
        Website: user.user_profile&.website,
        Company: DEFAULT_COMPANY_NAME,
        LeadSource: LEAD_SOURCE
      })

      user.custom_fields[ID_FIELD] = data["id"]
      user.save_custom_fields
    end
  end
end
