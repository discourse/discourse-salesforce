# frozen_string_literal: true

require "rails_helper"
require_relative "../spec_helper"

RSpec.describe Jobs::CreateCaseComment do
  include_context "with salesforce spec helper"

  fab!(:topic)
  fab!(:salesforce_case) { Fabricate(:salesforce_case, topic: topic) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  it "will not create comment if topic not linked to Salesforce case" do
    ::Salesforce::CaseComment.any_instance.expects(:create!).never
    described_class.new.execute(post_id: post.id)
  end

  it "will not create comment if post is already linked to one" do
    post.custom_fields[::Salesforce::CaseComment::ID_FIELD] = "CASE123"
    post.save_custom_fields

    topic.custom_fields["has_salesforce_case"] = true
    topic.save_custom_fields

    ::Salesforce::CaseComment.any_instance.expects(:create!).never
    described_class.new.execute(post_id: post.id)
  end

  it "creates a case comment object on Salesforce" do
    topic.custom_fields["has_salesforce_case"] = true
    topic.save_custom_fields

    ::Salesforce::CaseComment.any_instance.expects(:create!).once
    described_class.new.execute(post_id: post.id)
  end
end
