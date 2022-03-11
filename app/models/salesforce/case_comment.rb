# frozen_string_literal: true

module ::Salesforce
  class CaseComment < FeedItem
    ID_FIELD = "salesforce_case_comment_id"

    def payload
      {
        CommentBody: "@#{post.user.username}: #{post.raw}\n\n#{post.full_url}",
        ParentId: parent_id
      }
    end
  end
end
