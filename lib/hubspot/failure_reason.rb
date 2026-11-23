# frozen_string_literal: true

module Hubspot
  class FailureReason < DiscourseCrm::FailureReason
    CODES = {
      "CONTACT_SEARCH_LIMIT" => "contact_search_limit",
      "CONTACT_BATCH_REJECTED" => "batch_rejected",
      "UNEXPECTED_COMPANY" => "unexpected_company",
      "CONFLICTING_COMPANY_IDS" => "conflicting_company_ids",
      "INCOMPLETE_COMPANY_BATCH_READ" => "incomplete_company_batch_read",
      "INVALID_BATCH_READ_RESPONSE" => "batch_read",
      "INVALID_BATCH_WRITE_RESPONSE" => "batch_write",
      "BATCH_RESULT_UNCONFIRMED" => "batch_unconfirmed",
      "CONFLICT" => "duplicate_value",
      "MISSING_SCOPES" => "permissions",
      "VALIDATION_ERROR" => "validation",
      "INVALID_EMAIL" => "invalid_email",
      "INVALID_INTEGER" => "invalid_number",
      "INVALID_NUMBER" => "invalid_number",
      "INVALID_DATE" => "invalid_date",
      "INVALID_OPTION" => "invalid_option",
      "PROPERTY_DOESNT_EXIST" => "missing_property",
      "REQUIRED_FIELD" => "required_property",
      "READ_ONLY_VALUE" => "read_only",
    }.freeze

    EXCEPTIONS = {
      "Hubspot::ApiValidationError" => "validation",
      "Hubspot::InvalidPropertyValue" => "validation",
      "Hubspot::MissingContact" => "missing_contact",
      "Hubspot::InvalidCredentials" => "authentication",
      "Hubspot::RateLimited" => "rate_limit",
      "Hubspot::DailyQuotaExceeded" => "quota",
    }.freeze

    def message
      if attempt.error_class == "Hubspot::InvalidPropertyValue"
        properties = identifiers("properties")
        if properties.any?
          return translate("invalid_option_property", property: properties.join(", "))
        end
      end
      super
    end

    private

    def fallback
      if attempt.error_class == "Hubspot::InvalidApiResponse" && !diagnostics["status"]
        return "hubspot_unconfirmed"
      end
      super
    end
  end
end
