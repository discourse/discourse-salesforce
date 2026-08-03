# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUser < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.salesforce_enabled

      user = User.find(args[:user_id])
      begin
        unless ::Salesforce::Contact.sync(user)
          if lead_id = ::Salesforce::Lead.find_id_by_email(user.email)
            user.salesforce_lead_id = lead_id
            user.save_custom_fields
          end
        end
      rescue Salesforce::AmbiguousEmailMatch => error
        Rails.logger.warn(
          "Skipping Salesforce sync for Discourse user #{user.id}: multiple #{error.object_name} records have the same email",
        )
      rescue Salesforce::InvalidCredentials
      end
    end
  end
end
