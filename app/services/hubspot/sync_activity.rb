# frozen_string_literal: true

module Hubspot
  class SyncActivity
    extend DiscourseCrm::OutboundSyncActivity

    def self.record_failure(configuration, user_id, error)
      if error.is_a?(RateLimited)
        return DiscourseCrm::SyncAttempt.record(configuration, user_id, error: error)
      end
      if error.instance_of?(InvalidApiResponse)
        error = InvalidApiResponse.from_response(error.message, status: error.status)
      end
      attempt = super(configuration, user_id, error)
      if error.is_a?(InvalidPropertyValue)
        Rails.logger.warn(
          "HubSpot mapping rejected: configuration_id=#{configuration.id} user_id=#{user_id} property=#{error.property.to_json}",
        )
      end
      attempt
    end

    # Reports company changes on the users whose pulled contacts point to those companies.
    def self.record_company_results(configuration, references, result, started_at)
      user_column = "crm_record_links.user_id"
      changed = references.where(company_external_id: result.changed).distinct.pluck(user_column)
      changed.each do |user_id|
        DiscourseCrm::SyncAttempt.record(configuration, user_id, reason: "imported_company")
      end

      affected = references.where(company_external_id: result.changed + result.missing)
      missing = result.missing.size
      unchanged =
        references
          .where.not(user_column => affected.select(user_column))
          .distinct
          .count(user_column)
      {
        "missing_companies_summary" => missing,
        "unchanged_summary" => unchanged,
      }.each do |reason, count|
        if count.positive?
          DiscourseCrm::SyncAttempt.record_check_summary(
            configuration,
            started_at,
            count,
            reason: reason,
          )
        end
      end
      changed.any? || missing.positive? || unchanged.positive?
    end
  end
end
