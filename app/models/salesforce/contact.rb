# frozen_string_literal: true

module ::Salesforce
  class Contact < Person
    ID_FIELD = "salesforce_contact_id"
    SOURCE = "Web"
    OBJECT_NAME = "Contact"

    def self.group
      Salesforce.contacts_group
    end

    def self.payload
      user.salesforce_contact_payload
    end
  end
end
