# frozen_string_literal: true

module ::Salesforce
  class Case < Object

    CUSTOM_FIELD_NAME = "salesforce_case_id"

    def initialize(opts = {})
      super("case", opts)
    end

    def create!
      Contact.new(model: user).create! if user.salesforce_contact_id.blank?
      super do |payload|
        payload.merge!({
          Status: "New",
          Origin: ORIGIN,
          ContactId: user.salesforce_contact_id
        })
      end
    end
  end
end
