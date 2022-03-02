# frozen_string_literal: true

module ::Jobs
  class SyncCaseComments < ::Jobs::Base

    def execute(args)
      topic_id = args[:topic_id]
      post_id = args[:post_id]
      return if topic_id.blank?

      _case = ::Salesforce::Case.find_by(topic_id: topic_id)
      return if _case.blank?

      posts = Post.joins("LEFT JOIN post_custom_fields ON posts.id = post_custom_fields.post_id AND post_custom_fields.name = '#{::Salesforce::CaseComment::ID_FIELD}'")
                  .where(topic_id: topic_id, post_type: Post.types[:regular])
                  .where("post_custom_fields.value IS NULL")
                  .where.not(post_number: 1)
      posts = posts.where(id: post_id) if post_id.present?

      posts.find_each do |post|
        ::Salesforce::CaseComment.new(_case.uid, post).create!
      end
    end
  end
end
