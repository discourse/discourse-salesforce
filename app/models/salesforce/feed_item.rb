# frozen_string_literal: true

module ::Salesforce
  class FeedItem
    ID_FIELD = "salesforce_feed_item_id"

    def self.create!(post, uid)
      return if post.post_type != Post.types[:regular]

      body = post.raw
      body = yield(body) if block_given?

      payload = {
        Body: body,
        LinkUrl: post.full_url,
        Title: post.topic.title,
        Type: "LinkPost",
        Visibility: "InternalUsers",
        ParentId: uid
      }

      data = Api.new.post("sobjects/FeedItem", payload)

      post.custom_fields[ID_FIELD] = data["id"]
      post.save_custom_fields
    end
  end
end
