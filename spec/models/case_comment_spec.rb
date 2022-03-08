# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe Salesforce::CaseComment do
  include_context "spec helper"

  fab!(:topic) { Fabricate(:topic) }
  fab!(:_case) { Fabricate(:salesforce_case, topic: topic) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  it 'creates a case comment object on Salesforce' do
    case_comment = ::Salesforce::CaseComment.new(_case.uid, post)
    stub_request(:post, "#{api_path}/CaseComment").
         with(body: case_comment.payload.to_json).
         to_return(status: 200, body: { id: "case_comment_123" }.to_json, headers: {})

    topic.custom_fields["has_salesforce_case"] = true
    topic.save!

    case_comment.create!

    expect(post.custom_fields[::Salesforce::CaseComment::ID_FIELD]).to eq("case_comment_123")
  end
end
