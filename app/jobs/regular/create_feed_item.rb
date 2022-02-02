# frozen_string_literal: true

module ::Jobs
  class CreateFeedItem < ::Jobs::Base

    def execute(args)
      post_id = args[:post_id]
      return if post_id.blank?

      post = Post.find_by(id: post_id)
      return if post.blank? || post.post_type != Post.types[:regular] || post.custom_fields[::Salesforce::FeedItem::ID_FIELD].present?

      topic = post.topic
      return if topic.blank?

      uid = nil
      if topic.has_salesforce_case
        uid = topic.salesforce_case.uid
      else
        user = post.user
        uid = user.salesforce_contact_id || user.salesforce_lead_id
      end
      return if uid.blank?

      ::Salesforce::FeedItem.create!(post, uid) do |body|
        topic.has_salesforce_case ? "@#{post.user.username}: #{body}" : body
      end
    end
  end
end
