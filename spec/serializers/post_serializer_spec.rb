# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostSerializer do
  include_context "with hubspot spec helper"

  fab!(:viewers, :group)
  fab!(:viewer) { Fabricate(:user, groups: [viewers]) }
  fab!(:outsider, :user)
  fab!(:lead_user, :verified_user)
  fab!(:topic)
  fab!(:lead_post) { Fabricate(:post, topic:, user: lead_user) }
  fab!(:other_post) { Fabricate(:post, topic:, user: outsider) }

  let!(:configuration) do
    Fabricate(
      :hubspot_sync_configuration,
      mappings: [{ "id" => 1, "object" => "contact", "source" => "lifecyclestage" }],
    )
  end
  let!(:segment) do
    Fabricate(
      :crm_segment,
      configuration:,
      flair_enabled: true,
      flair_text_property: "contact.lifecyclestage",
      flair_group_ids: [viewers.id],
    )
  end

  before do
    SiteSetting.crm_segments_enabled = true
    Fabricate(:crm_record, external_id: "501", data: { "lifecyclestage" => "lead" })
    DiscourseCrm::RecordLink.link_many!(
      [
        {
          provider: "hubspot",
          account: "12345",
          object: "contact",
          direction: "inbound",
          user_id: lead_user.id,
          external_id: "501",
        },
      ],
    )
    segment.members.create!(user: lead_user)
  end

  def serialized_posts(user)
    topic_view = TopicView.new(topic, user)
    TopicViewSerializer.new(topic_view, scope: Guardian.new(user), root: false).as_json[
      :post_stream
    ][
      :posts
    ]
  end

  it "adds the flair of members for viewers in the flair groups" do
    posts = serialized_posts(viewer)

    expect(posts.find { |post| post[:id] == lead_post.id }[:crm_flair]).to eq(
      provider: "hubspot",
      icon: "fab-hubspot",
      text: "lead",
      properties: [],
      url: "https://app.hubspot.com/contacts/12345/record/0-1/501",
    )
    expect(posts.find { |post| post[:id] == other_post.id }).not_to have_key(:crm_flair)
  end

  it "leaves the flair out for other viewers, anonymous viewers and while segments are disabled" do
    expect(serialized_posts(outsider).map { |post| post.key?(:crm_flair) }).to all(eq(false))
    expect(serialized_posts(nil).map { |post| post.key?(:crm_flair) }).to all(eq(false))

    SiteSetting.crm_segments_enabled = false
    expect(serialized_posts(viewer).map { |post| post.key?(:crm_flair) }).to all(eq(false))
  end

  it "loads the flairs of a topic once rather than per post" do
    queries =
      track_sql_queries do
        topic_view = TopicView.new(topic, viewer)
        TopicViewSerializer.new(topic_view, scope: Guardian.new(viewer), root: false).as_json
      end

    expect(queries.count { |query| query.include?("crm_segment_members") }).to eq(1)
    expect(queries.count { |query| query.include?("crm_record_links") }).to eq(1)
  end

  it "builds the flair for a post serialized outside a topic view" do
    json = described_class.new(lead_post, scope: Guardian.new(viewer), root: false).as_json

    expect(json[:crm_flair][:text]).to eq("lead")
  end

  it "looks the viewer's flair segments up once per request outside a topic view" do
    guardian = Guardian.new(viewer)
    queries =
      track_sql_queries do
        [lead_post, other_post].each do |post|
          described_class.new(post, scope: guardian, root: false).as_json
        end
      end

    expect(queries.count { |query| query.include?("crm_segments") }).to eq(1)
  end
end
