# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe Salesforce::FeedItem do
  include_context "with salesforce spec helper"

  fab!(:user) { Fabricate(:user) }
  fab!(:post) { Fabricate(:post, user: user) }

  describe '#create!' do
    it 'creates a feed item on Salesforce lead object' do
      user.salesforce_lead_id = "lead_123"
      user.save!

      feed_item = ::Salesforce::FeedItem.new(user.salesforce_lead_id, post)
      stub_request(:post, "#{api_path}/FeedItem").
        with(body: feed_item.payload.to_json).
        to_return(status: 200, body: { id: "feed_item_123" }.to_json, headers: {})

      feed_item.create!

      expect(post.custom_fields[::Salesforce::FeedItem::ID_FIELD]).to eq("feed_item_123")
    end
  end
end
