# frozen_string_literal: true

module ::Jobs
  class CreateCaseComment < ::Jobs::Base

    def execute(args)
      post_id = args[:post_id]
      return if post_id.blank?

      post = Post.find_by(id: post_id)
      return if post.blank? || post.post_type != Post.types[:regular] || post.custom_fields[::Salesforce::CaseComment::ID_FIELD].present?

      topic = post.topic
      return unless topic.present? && topic.has_salesforce_case

      ::Salesforce::CaseComment.new(topic.salesforce_case.uid, post).create!
    end
  end
end
