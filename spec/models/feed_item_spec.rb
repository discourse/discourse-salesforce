# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::FeedItem do
  include_context "with salesforce spec helper"

  fab!(:user)
  fab!(:post) { Fabricate(:post, user: user) }

  describe "#create!" do
    it "creates a feed item on Salesforce lead object" do
      user.salesforce_lead_id = "lead_123"
      user.save!

      feed_item = ::Salesforce::FeedItem.new(user.salesforce_lead_id, post)
      stub_request(:post, "#{api_path}/FeedItem").with(body: feed_item.payload.to_json).to_return(
        status: 200,
        body: { id: "feed_item_123" }.to_json,
        headers: {
        },
      )

      feed_item.create!

      expect(post.custom_fields[::Salesforce::FeedItem::ID_FIELD]).to eq("feed_item_123")
    end

    it "does not export private message replies or consume their quota" do
      SiteSetting.salesforce_max_feed_items_per_day = 1
      private_post =
        Fabricate(
          :post,
          user: user,
          topic: Fabricate(:private_message_topic, user: user),
          post_number: 2,
        )
      feed_item = ::Salesforce::FeedItem.new("lead_123", private_post)
      salesforce_request =
        stub_request(:post, "#{api_path}/FeedItem").to_return(
          status: 200,
          body: { id: "feed_item_123" }.to_json,
        )
      RateLimiter.enable
      limiter =
        RateLimiter.new(
          nil,
          "#{::Salesforce::FeedItem::ID_FIELD}_lead_123",
          SiteSetting.salesforce_max_feed_items_per_day,
          1.day,
        )
      limiter.clear!

      expect(private_post.post_type).to eq(Post.types[:regular])
      expect(private_post.post_number).to eq(2)
      expect(limiter.can_perform?).to eq(true)

      feed_item.create!

      expect(salesforce_request).not_to have_been_requested
      expect(private_post.custom_fields[::Salesforce::FeedItem::ID_FIELD]).to be_nil
      expect(limiter.remaining).to eq(1)
    ensure
      limiter&.clear!
      RateLimiter.disable
    end
  end
end
