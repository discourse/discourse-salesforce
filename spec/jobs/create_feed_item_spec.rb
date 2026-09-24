# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::CreateFeedItem do
  include_context "with salesforce spec helper"

  fab!(:user)
  fab!(:post) { Fabricate(:post, user: user) }

  it "will not create feed item if user not linked to Salesforce lead" do
    ::Salesforce::FeedItem.any_instance.expects(:create!).never
    described_class.new.execute(post_id: post.id)
  end

  it "will not create feed item if post is already linked to one" do
    post.custom_fields[::Salesforce::FeedItem::ID_FIELD] = "feed_123"
    post.save_custom_fields

    user.salesforce_lead_id = "lead_123"
    user.save_custom_fields

    ::Salesforce::FeedItem.any_instance.expects(:create!).never
    described_class.new.execute(post_id: post.id)
  end

  it "creates a feed item on Salesforce lead object" do
    user.salesforce_lead_id = "lead_123"
    user.save_custom_fields

    ::Salesforce::FeedItem.any_instance.expects(:create!).once
    described_class.new.execute(post_id: post.id)
  end

  it "skips Lead feed items when Salesforce Leads are disabled" do
    SiteSetting.salesforce_leads_enabled = false
    user.salesforce_lead_id = "lead_123"
    user.save_custom_fields

    described_class.new.execute(post_id: post.id)

    expect(a_request(:post, %r{/sobjects/FeedItem})).not_to have_been_made
  end
end
