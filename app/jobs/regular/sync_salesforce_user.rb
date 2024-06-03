# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUser < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.salesforce_enabled

      user = User.find(args[:user_id])
      if user.salesforce_contact_id = ::Salesforce::Contact.find_id_by_email(user.email)
        user.save_custom_fields
      elsif user.salesforce_lead_id = ::Salesforce::Lead.find_id_by_email(user.email)
        user.save_custom_fields
      end
    end
  end
end
