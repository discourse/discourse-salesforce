# frozen_string_literal: true

module Salesforce
  class SyncActivity
    extend DiscourseCrm::OutboundSyncActivity

    def self.record_converted_lead(configuration, user_id, scheduled: false)
      configuration.record_result(user_id, reason: "skipped_converted", summarize_repeat: scheduled)
    end

    def self.record_existing_contact(configuration, user_id)
      configuration.transaction do
        configuration.record_result(user_id, reason: "skipped_existing_contact")
        configuration.sync_states.where(user_id: user_id).update_all(fingerprint: nil)
      end
    end

    def self.record_reconciliation(configuration, user_id, error:)
      if error
        record_failure(configuration, user_id, error)
      else
        DiscourseCrm::SyncAttempt.record(configuration, user_id, reason: "skipped_reconciliation")
      end
    end
  end
end
