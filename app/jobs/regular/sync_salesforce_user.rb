# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUser < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      return unless SiteSetting.salesforce_enabled

      if args[:configuration_id]
        begin
          ::Salesforce::ConfiguredUserSync.sync(
            args[:configuration_id],
            args[:user_id],
            reason: args[:reason],
          )
        rescue => error
          ::Salesforce::SyncConfiguration.record_result(
            args[:configuration_id],
            args[:user_id],
            error: error,
          )
          unless error.is_a?(Discourse::InvalidParameters) ||
                   error.is_a?(Salesforce::AmbiguousEmailMatch)
            raise
          end
          Rails.logger.warn(
            "Salesforce configured sync stopped: configuration_id=#{args[:configuration_id]} user_id=#{args[:user_id]} error=#{error.class.name}",
          )
        end
        return
      end

      user = User.find(args[:user_id])
      lock_key = "salesforce_person_create_#{user.id}"
      return if DistributedMutex.synchronize(lock_key) { ::Salesforce::Contact.sync(user) }

      lead_id = nil
      if ::Salesforce.leads_enabled?
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
        DistributedMutex.synchronize(lock_key) do
          ::Salesforce::Lead.link!(user, lead_id, created: false)
        end
      elsif SiteSetting.salesforce_contact_auto_create_on_signup &&
            ::Salesforce::Person.auto_create_eligible?(user)
        user.create_salesforce_contact
      end
    rescue Salesforce::AmbiguousEmailMatch => error
      raise if args[:configuration_id]
      Rails.logger.warn(
        "Skipping Salesforce sync for Discourse user #{user.id}: multiple #{error.object_name} records have the same email",
      )
    rescue Salesforce::InvalidApiResponse => error
      raise if args[:configuration_id]
      raise if error.status.nil? || error.status == 429 || error.status >= 500
      Rails.logger.warn("Skipping Salesforce sync for Discourse user #{user.id}: #{error.message}")
    rescue Salesforce::InvalidCredentials
      raise if args[:configuration_id]
    end
  end
end
