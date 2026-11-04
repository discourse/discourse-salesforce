# frozen_string_literal: true

module Jobs
  class SyncSalesforceConfigurations < ::Jobs::Scheduled
    every 1.hour

    def execute(args)
      Salesforce::ConfigurationScheduler.enqueue_due
    end
  end
end
