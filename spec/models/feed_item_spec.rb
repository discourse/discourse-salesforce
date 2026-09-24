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

    it "sends the visibility configured in salesforce_feed_item_visibility" do
      SiteSetting.salesforce_feed_item_visibility = "AllUsers"
      user.salesforce_lead_id = "lead_123"
      user.save!

      create_feed_item =
        stub_request(:post, "#{api_path}/FeedItem").with(
          body: hash_including(Visibility: "AllUsers"),
        ).to_return(status: 200, body: { id: "feed_item_123" }.to_json)

      ::Salesforce::FeedItem.new(user.salesforce_lead_id, post).create!

      expect(create_feed_item).to have_been_requested
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

    it "does not post replies when the daily limit is zero" do
      reply = Fabricate(:post, topic: post.topic, user: user)
      SiteSetting.salesforce_max_feed_items_per_day = 0
      RateLimiter.enable

      feed_item = ::Salesforce::FeedItem.new("lead_123", reply)
      salesforce_request =
        stub_request(:post, "#{api_path}/FeedItem").with(body: feed_item.payload.to_json).to_return(
          status: 200,
          body: { id: "feed_item_123" }.to_json,
        )

      expect { feed_item.create! }.not_to raise_error
      expect(salesforce_request).not_to have_been_requested
      expect(reply.custom_fields[::Salesforce::FeedItem::ID_FIELD]).to be_nil
    ensure
      RateLimiter.disable
    end

    it "does not post a reply after the daily limit is exhausted" do
      SiteSetting.salesforce_max_feed_items_per_day = 1
      parent_id = "lead_#{post.topic_id}"
      first_post_feed_item = ::Salesforce::FeedItem.new(parent_id, post)
      first_reply = Fabricate(:post, topic: post.topic, user: user)
      first_reply_feed_item = ::Salesforce::FeedItem.new(parent_id, first_reply)
      limited_reply = Fabricate(:post, topic: post.topic, user: user)
      limited_feed_item = ::Salesforce::FeedItem.new(parent_id, limited_reply)
      RateLimiter.enable
      limiter =
        RateLimiter.new(
          nil,
          "#{::Salesforce::FeedItem::ID_FIELD}_#{parent_id}",
          SiteSetting.salesforce_max_feed_items_per_day,
          1.day,
        )
      limiter.clear!

      first_post_request =
        stub_request(:post, "#{api_path}/FeedItem").with(
          body: first_post_feed_item.payload.to_json,
        ).to_return(status: 200, body: { id: "feed_item_123" }.to_json)
      first_reply_request =
        stub_request(:post, "#{api_path}/FeedItem").with(
          body: first_reply_feed_item.payload.to_json,
        ).to_return(status: 200, body: { id: "feed_item_456" }.to_json)
      limited_reply_request =
        stub_request(:post, "#{api_path}/FeedItem").with(
          body: limited_feed_item.payload.to_json,
        ).to_return(status: 200, body: { id: "feed_item_789" }.to_json)

      expect { first_post_feed_item.create! }.not_to raise_error
      expect { first_reply_feed_item.create! }.not_to raise_error
      expect { limited_feed_item.create! }.not_to raise_error

      expect(first_post_request).to have_been_requested
      expect(first_reply_request).to have_been_requested
      expect(limited_reply_request).not_to have_been_requested
      expect(limited_reply.custom_fields[::Salesforce::FeedItem::ID_FIELD]).to be_nil
    ensure
      limiter&.clear!
      RateLimiter.disable
    end
  end
end
