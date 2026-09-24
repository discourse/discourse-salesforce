# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostsController do
  include_context "with salesforce spec helper"

  fab!(:author) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:recipient) { Fabricate(:user, refresh_auto_groups: true) }

  describe "#create" do
    before do
      Jobs.run_immediately!
      author.salesforce_lead_id = "lead_123"
      author.save_custom_fields
      sign_in(author)
    end

    it "does not export private message contents to Salesforce" do
      private_message_body = "Private message only for the recipient"
      salesforce_feed_item =
        stub_request(:post, "#{api_path}/FeedItem").with(
          body: /"Body":"#{private_message_body}"/,
        ).to_return(status: 200, body: { id: "feed_item_123" }.to_json)

      post "/posts.json",
           params: {
             raw: private_message_body,
             title: "A private message title",
             archetype: Archetype.private_message,
             target_recipients: recipient.username,
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["id"]).to be_present
      expect(salesforce_feed_item).not_to have_been_requested
    end
  end
end
