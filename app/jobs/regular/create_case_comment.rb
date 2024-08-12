# frozen_string_literal: true

module ::Jobs
  class CreateCaseComment < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.salesforce_enabled

      post_id = args[:post_id]
      return if post_id.blank?

      post = Post.find_by(id: post_id, post_type: Post.types[:regular])
      return if post.blank? || post.custom_fields[::Salesforce::CaseComment::ID_FIELD].present?

      topic = post.topic
      return unless topic.present? && topic.has_salesforce_case

      begin
        ::Salesforce::CaseComment.new(topic.salesforce_case.uid, post).create!
      rescue Salesforce::InvalidCredentials
      end
    end
  end
end
