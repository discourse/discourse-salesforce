# frozen_string_literal: true

module Jobs
  class SyncHubspotUser < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      configuration = Salesforce::SyncConfiguration.active.find_by(id: args[:configuration_id])
      return unless configuration&.reason_enabled?(args[:reason])
      user = Salesforce::Person.eligible_users.find_by(id: args[:user_id])
      return unless user

      Hubspot::ContactImport.new(configuration).import_user(user)
      Salesforce::SyncState.where(configuration_id: configuration.id, user_id: user.id).update_all(
        error: nil,
        error_at: nil,
      )
    rescue => error
      Salesforce::SyncConfiguration.record_result(
        args[:configuration_id],
        args[:user_id],
        error: error,
      )
      raise unless error.is_a?(Discourse::InvalidParameters)
      Rails.logger.warn(
        "HubSpot user import stopped: configuration_id=#{args[:configuration_id]} user_id=#{args[:user_id]} error=#{error.class.name}",
      )
    end
  end
end
