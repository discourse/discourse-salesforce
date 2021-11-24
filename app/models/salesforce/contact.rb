# frozen_string_literal: true

module ::Salesforce
  class Contact < Object

    CUSTOM_FIELD_NAME = "salesforce_contact_id"

    def initialize(opts = {})
      opts.merge!(include_user_payload: true)
      super("contact", opts)
    end

    def create!
      super do |payload|
        payload.merge!(LeadSource: ORIGIN)
      end
    end
  end
end
