# frozen_string_literal: true

module ::Jobs
  class SyncCase < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.salesforce_enabled

      topic = Topic.find(args[:topic_id])
      begin
        ::Salesforce::Case.sync!(topic)
      rescue Salesforce::InvalidCredentials
      end
    end
  end
end
