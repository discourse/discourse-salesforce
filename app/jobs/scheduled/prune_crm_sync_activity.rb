# frozen_string_literal: true

module Jobs
  class PruneCrmSyncActivity < ::Jobs::Scheduled
    every 1.day

    def execute(_args)
      days = SiteSetting.crm_sync_activity_retention_days
      return if days.zero?

      ::DiscourseCrm::SyncAttempt
        .where(created_at: ...days.days.ago)
        .in_batches(of: 1_000)
        .delete_all
    end
  end
end
