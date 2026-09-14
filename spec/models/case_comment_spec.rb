# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::CaseComment do
  include_context "with salesforce spec helper"

  fab!(:topic)
  fab!(:salesforce_case) { Fabricate(:salesforce_case, topic: topic) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  describe "#create!" do
    { "AllUsers" => true, "InternalUsers" => false }.each do |visibility, published|
      it "sets case comment publication to #{published} for #{visibility}" do
        SiteSetting.salesforce_feed_item_visibility = visibility

        create_case_comment =
          stub_request(:post, "#{api_path}/CaseComment").with(
            body: hash_including("ParentId" => salesforce_case.uid, "IsPublished" => published),
          ).to_return(status: 201, body: { id: "case_comment_123" }.to_json)

        described_class.new(salesforce_case.uid, post).create!

        expect(create_case_comment).to have_been_requested
        expect(post.reload.custom_fields[described_class::ID_FIELD]).to eq("case_comment_123")
      end
    end

    it "creates a case comment object on Salesforce" do
      case_comment = ::Salesforce::CaseComment.new(salesforce_case.uid, post)
      stub_request(:post, "#{api_path}/CaseComment").with(
        body: case_comment.payload.to_json,
      ).to_return(status: 200, body: { id: "case_comment_123" }.to_json, headers: {})

      topic.custom_fields["has_salesforce_case"] = true
      topic.save!

      case_comment.create!

      expect(post.custom_fields[::Salesforce::CaseComment::ID_FIELD]).to eq("case_comment_123")
    end

    it "does not post replies when the daily limit is zero" do
      reply = Fabricate(:post, topic: topic)
      SiteSetting.salesforce_max_feed_items_per_day = 0
      RateLimiter.enable

      case_comment = ::Salesforce::CaseComment.new(salesforce_case.uid, reply)
      salesforce_request =
        stub_request(:post, "#{api_path}/CaseComment").with(
          body: case_comment.payload.to_json,
        ).to_return(status: 200, body: { id: "case_comment_123" }.to_json)

      expect { case_comment.create! }.not_to raise_error
      expect(salesforce_request).not_to have_been_requested
      expect(reply.custom_fields[::Salesforce::CaseComment::ID_FIELD]).to be_nil
    ensure
      RateLimiter.disable
    end
  end
end
