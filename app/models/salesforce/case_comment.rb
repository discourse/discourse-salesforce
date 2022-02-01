# frozen_string_literal: true

module ::Salesforce
  class CaseComment
    ID_FIELD = "salesforce_case_comment_id"

    def self.create!(post)
      _case = Case.find_by(topic_id: post.topic_id)
      return if _case.blank?

      user = post.user
      payload = {
        CommentBody: post.raw,
        ParentId: _case.uid
      }

      data = Api.new.post("sobjects/CaseComment", payload)

      post.custom_fields[ID_FIELD] = data["id"]
      post.save_custom_fields
    end
  end
end
