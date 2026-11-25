# frozen_string_literal: true

module DiscourseCrm
  class SyncAttemptSerializer < ApplicationSerializer
    attributes :id,
               :configuration,
               :user_id,
               :username,
               :provider,
               :direction,
               :outcome,
               :reason,
               :created_at,
               :failure_reason,
               :rejected_email,
               :summary_count

    attribute :crm_object, key: :object

    def include_summary_count?
      %w[
        unchanged_summary
        still_missing_summary
        missing_companies_summary
        skipped_converted_summary
      ].include?(object.reason)
    end

    def summary_count
      object.diagnostics.fetch("count")
    end

    def include_failure_reason?
      object.outcome == "failed"
    end

    alias include_rejected_email? include_failure_reason?

    def failure_reason
      FailureReason.for(object)
    end

    def rejected_email
      values = object.diagnostics["rejected_values"]
      return unless values.is_a?(Array) && values.size == 1
      rejected = values.first
      return unless rejected.is_a?(Hash) && rejected["property"] == "email"
      email = rejected["value"]
      if email.is_a?(String) &&
           object.user&.user_emails&.any? { |address| address.email.casecmp?(email) }
        email
      end
    end

    def crm_object
      object.object
    end

    def configuration
      object.configuration&.slice(:id, :name)
    end

    def username
      object.user&.username
    end
  end
end
