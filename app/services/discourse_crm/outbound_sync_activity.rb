# frozen_string_literal: true

module DiscourseCrm
  module OutboundSyncActivity
    def record_write(configuration, user_id, created:, changed:)
      reason = created ? "created" : (changed ? "updated" : "unchanged")
      configuration.record_result(user_id, reason: reason)
    end

    def record_failure(configuration, user_id, error)
      configuration.record_result(user_id, error: error)
    end
  end
end
