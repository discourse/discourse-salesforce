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
  end
end
