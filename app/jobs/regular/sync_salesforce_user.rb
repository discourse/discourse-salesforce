# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUser < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      return unless SiteSetting.salesforce_enabled

      user = User.find(args[:user_id])
      begin
        unless ::Salesforce::Contact.sync(user)
          if lead_id = ::Salesforce::Lead.find_id_by_email(user.email)
            user.salesforce_lead_id = lead_id
            user.save_custom_fields
          elsif SiteSetting.salesforce_contact_auto_create_on_signup &&
                ::Salesforce::Person.auto_create_eligible?(user)
            create_contact(user)
          end
        end
      rescue Salesforce::AmbiguousEmailMatch => error
        Rails.logger.warn(
          "Skipping Salesforce sync for Discourse user #{user.id}: multiple #{error.object_name} records have the same email",
        )
      rescue Salesforce::InvalidCredentials
      end
    end

    private

    def create_contact(user)
      user.create_salesforce_contact
    rescue Salesforce::InvalidApiResponse => error
      raise if error.status.nil? || error.status == 429 || error.status >= 500
      Rails.logger.warn(
        "Skipping Salesforce contact creation for Discourse user #{user.id}: #{error.message}",
      )
    end
  end
end
