# frozen_string_literal: true

module ::Jobs
  class SyncCase < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.salesforce_enabled

      topic = Topic.find(args[:topic_id])
      sync_tags = SiteSetting.salesforce_automatic_case_sync_tags.split("|")
      return if !topic.has_salesforce_case && sync_tags.intersection(topic.tags.pluck(:name)).empty?

      begin
        ::Salesforce::Case.sync!(topic)
      rescue Salesforce::InvalidCredentials
      end
    end
  end
end
