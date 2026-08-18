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
          elsif SiteSetting.salesforce_auto_create_contact_on_signup &&
                eligible_for_contact_creation?(user)
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

    def eligible_for_contact_creation?(user)
      user.active? && user.human? && !user.anonymous? && !user.staged? && !user.suspended?
    end

    def create_contact(user)
      user.create_salesforce_contact
    rescue Salesforce::InvalidApiResponse => error
      # Duplicate or validation rules reject the record permanently, so retrying
      # cannot succeed; transient failures propagate and retry via Sidekiq.
      raise if error.status != 400
      Rails.logger.warn(
        "Skipping Salesforce contact creation for Discourse user #{user.id}: #{error.message}",
      )
    end
  end
end
