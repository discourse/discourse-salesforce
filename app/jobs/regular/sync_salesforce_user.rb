# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUser < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.salesforce_enabled

      user = User.find(args[:user_id])
      begin
        ::Salesforce::Contact.sync(user) || ::Salesforce::Lead.sync(user)
      rescue Salesforce::AmbiguousEmailMatch => error
        Rails.logger.warn(
          "Skipping Salesforce sync for Discourse user #{user.id}: multiple #{error.object_name} records have the same email",
        )
      rescue Salesforce::InvalidCredentials
      end
    end
  end
end
