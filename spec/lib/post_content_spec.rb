# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::PostContent do
  fab!(:upload)

  fab!(:post) { Fabricate(:post, raw: <<~MD) }
        **Important** update with a [link](https://example.com/docs) and a file:

        [report.pdf|attachment](#{upload.short_url})
      MD

  describe ".body_for" do
    it "returns the raw markdown by default" do
      expect(described_class.body_for(post)).to eq(post.raw)
    end

    context "when salesforce_send_rendered_post_content is enabled" do
      before { SiteSetting.salesforce_send_rendered_post_content = true }

      it "renders readable text with every reference resolved to a full URL" do
        text = described_class.body_for(post)

        expect(text).to include("Important update with a link (https://example.com/docs)")
        expect(text).to include("report.pdf (#{Discourse.base_url}/uploads/short-url/")
        expect(text).not_to include("**")
        expect(text).not_to include("upload://")
        expect(text).not_to include("<")
      end

      it "renders headings and images without anchor or scheme artifacts" do
        heading_post =
          Fabricate(:post, raw: "## Update\n\nsee:\n\n![screenshot](#{upload.short_url})")

        text = described_class.body_for(heading_post)

        expect(text).to include("Update")
        expect(text).not_to include("#p-")
        expect(text).to match(%r{screenshot: https?://[^/]+/uploads/})
        expect(text).not_to match(%r{\s//})
      end

      it "truncates to the requested length" do
        expect(described_class.body_for(post, max_length: 20).length).to be <= 20
      end

      it "flows into case comment and feed item payloads" do
        comment_body = ::Salesforce::CaseComment.new("case_1", post).payload[:CommentBody]
        feed_body = ::Salesforce::FeedItem.new("contact_1", post).payload[:Body]

        expect(comment_body).to include("link (https://example.com/docs)")
        expect(comment_body).not_to include("**")
        expect(feed_body).to include("link (https://example.com/docs)")
        expect(feed_body).not_to include("upload://")
      end
    end
  end
end
