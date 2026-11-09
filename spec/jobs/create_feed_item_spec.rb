# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::CreateFeedItem do
  include_context "with salesforce spec helper"

  fab!(:user)
  fab!(:post) { Fabricate(:post, user: user) }

  before do
    Salesforce.seed_groups!
    Salesforce.leads_group.add(user)
  end

  it "does not create feed item if user not linked to Salesforce lead" do
    ::Salesforce::FeedItem.any_instance.expects(:create!).never
    described_class.new.execute(post_id: post.id)
  end

  it "does not create feed item if post is already linked to one" do
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

  it "propagates a temporary authentication outage and creates the feed item on retry" do
    user.salesforce_contact_id = "contact_123"
    user.save_custom_fields
    stub_request(:post, "https://login.salesforce.com/services/oauth2/token")
      .to_return(status: 503, body: "Unavailable")
      .then
      .to_return(status: 200, body: api_response_body)
    create =
      stub_request(:post, "#{api_path}/FeedItem").to_return(
        status: 201,
        body: { id: "feed_123" }.to_json,
      )

    expect { described_class.new.execute(post_id: post.id) }.to raise_error(
      Salesforce::InvalidApiResponse,
    ) { |error| expect(error.status).to eq(503) }
    expect(post.reload.custom_fields[Salesforce::FeedItem::ID_FIELD]).to be_nil

    described_class.new.execute(post_id: post.id)

    expect(create).to have_been_requested.once
    expect(post.reload.custom_fields[Salesforce::FeedItem::ID_FIELD]).to eq("feed_123")
  end

  it "skips Lead feed items when Leads are disabled" do
    SiteSetting.salesforce_leads_enabled = false
    Salesforce.leads_group.users.clear
    user.salesforce_lead_id = "lead_123"
    user.save_custom_fields

    described_class.new.execute(post_id: post.id)

    expect(a_request(:post, %r{/sobjects/FeedItem})).not_to have_been_made
  end

  it "exports to an existing Contact when Leads are disabled and an old Lead link remains" do
    SiteSetting.salesforce_leads_enabled = false
    Salesforce.leads_group.users.clear
    user.salesforce_contact_id = "contact_123"
    user.salesforce_lead_id = "lead_123"
    user.save_custom_fields
    create_request =
      stub_request(:post, "#{api_path}/FeedItem").with(
        body: hash_including(ParentId: user.salesforce_contact_id),
      ).to_return(status: 201, body: %({"id":"feed_123"}))

    described_class.new.execute(post_id: post.id)

    expect(create_request).to have_been_requested
    expect(post.reload.custom_fields[Salesforce::FeedItem::ID_FIELD]).to eq("feed_123")
    expect(user.reload.salesforce_lead_id).to eq("lead_123")
  end
end
