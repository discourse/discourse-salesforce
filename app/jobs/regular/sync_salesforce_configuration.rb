# frozen_string_literal: true

module Jobs
  # Retain the job name for work queued before the shared scheduler was introduced.
  class SyncSalesforceConfiguration < ::Jobs::DiscourseCrm::SyncOutboundConfiguration
  end
end
