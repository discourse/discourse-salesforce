# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUser < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      return unless SiteSetting.salesforce_enabled

      user = User.find(args[:user_id])
      return if ::Salesforce::Contact.sync(user)

      lead_id = nil
      if SiteSetting.salesforce_leads_enabled
        begin
          lead_id = ::Salesforce::Lead.find_id_by_email(user.email)
        rescue Salesforce::InvalidApiResponse => error
          # Salesforce answers INVALID_TYPE when the API user cannot see the Lead object
          # (Leads disabled or not licensed), so treat it as "no lead" and keep going.
          unless error.status == 400 && error.message.match?(/"errorCode"\s*:\s*"INVALID_TYPE"/)
            raise
          end
        end
      end

      if lead_id
        user.salesforce_lead_id = lead_id
        user.save_custom_fields
      elsif SiteSetting.salesforce_contact_auto_create_on_signup &&
            ::Salesforce::Person.auto_create_eligible?(user)
        user.create_salesforce_contact
      end
    rescue Salesforce::AmbiguousEmailMatch => error
      Rails.logger.warn(
        "Skipping Salesforce sync for Discourse user #{user.id}: multiple #{error.object_name} records have the same email",
      )
    rescue Salesforce::InvalidApiResponse => error
      raise if error.status.nil? || error.status == 429 || error.status >= 500
      Rails.logger.warn("Skipping Salesforce sync for Discourse user #{user.id}: #{error.message}")
    rescue Salesforce::InvalidCredentials
    end
  end
end
