# frozen_string_literal: true

module Salesforce
  class FailureReason < DiscourseCrm::FailureReason
    CODES = {
      "DUPLICATES_DETECTED" => "duplicate_detected",
      "DUPLICATE_VALUE" => "duplicate_value",
      "REQUIRED_FIELD_MISSING" => "required_property",
      "INVALID_EMAIL_ADDRESS" => "invalid_email",
      "INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST" => "invalid_option",
      "FIELD_CUSTOM_VALIDATION_EXCEPTION" => "validation_rule",
      "INSUFFICIENT_ACCESS_OR_READONLY" => "permissions",
      "INVALID_FIELD_FOR_INSERT_UPDATE" => "field_not_writable",
      "STRING_TOO_LONG" => "value_too_long",
      "MALFORMED_ID" => "malformed_id",
      "UNABLE_TO_LOCK_ROW" => "locked_record",
      "INVALID_TYPE" => "unavailable_object",
    }.freeze

    EXCEPTIONS = {
      "Salesforce::InvalidCredentials" => "authentication",
      "Salesforce::ConfiguredUserBatchSync::UnconfirmedCollectionResult" =>
        "salesforce_unconfirmed",
      "Salesforce::AmbiguousEmailMatch" => "ambiguous",
      "Salesforce::LeadConversionReconciliationError" => "conversion",
    }.freeze
  end
end
