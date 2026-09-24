# frozen_string_literal: true

module ::Jobs
  class CreateFeedItem < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.salesforce_enabled

      post_id = args[:post_id]
      return if post_id.blank?

      post = Post.find_by(id: post_id, post_type: Post.types[:regular])
      return if post.blank? || post.custom_fields[::Salesforce::FeedItem::ID_FIELD].present?

      user = post.user
      uid = user.salesforce_contact_id
      uid ||= user.salesforce_lead_id if SiteSetting.salesforce_leads_enabled
      return if uid.blank?

      begin
        ::Salesforce::FeedItem.new(uid, post).create!
      rescue Salesforce::InvalidCredentials
      end
    end
  end
end
