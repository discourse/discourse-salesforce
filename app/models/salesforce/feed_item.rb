# frozen_string_literal: true

module ::Salesforce
  class FeedItem
    ID_FIELD = "salesforce_feed_item_id"

    attr_reader :parent_id, :post, :max_feed_items

    def initialize(uid, post)
      @parent_id = uid
      @post = post
      @max_feed_items = SiteSetting.salesforce_max_feed_items_per_day
    end

    def create!
      return if post.post_type != Post.types[:regular]

      limiter = RateLimiter.new(nil, "#{self.class::ID_FIELD}_#{parent_id}", max_feed_items, 1.day)
      limiter.performed! if has_rate_limit? && !limiter.can_perform?

      data = Api.new.post("sobjects/#{self.class.name.demodulize}", payload)
      limiter.performed! if has_rate_limit?

      post.custom_fields[self.class::ID_FIELD] = data["id"]
      post.save_custom_fields
    end

    def payload
      {
        Body: post.raw,
        LinkUrl: post.full_url,
        Title: post.topic.title,
        Type: "LinkPost",
        Visibility: "InternalUsers",
        ParentId: parent_id,
      }
    end

    def has_rate_limit?
      max_feed_items > -1 && post.post_number > 1
    end
  end
end
