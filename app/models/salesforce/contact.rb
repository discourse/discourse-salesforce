# frozen_string_literal: true

module ::Salesforce
  class Contact < Person
    ID_FIELD = "salesforce_contact_id"
    SOURCE = "Web"
    OBJECT_NAME = "Contact"

    def self.group
      Salesforce.contacts_group
    end

    def self.payload(user)
      user.salesforce_contact_payload
    end

    def self.sync_mode
      SiteSetting.salesforce_contact_sync_mode
    end

    def self.fields_to_sync
      SiteSetting.salesforce_contact_sync_fields.split("|").map(&:to_sym)
    end
  end
end
