# frozen_string_literal: true

module ::Jobs
  class SyncCase < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.salesforce_enabled

      topic = Topic.find(args[:topic_id])
      ::Salesforce::Case.sync!(topic)
    end
  end
end
