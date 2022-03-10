# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe Jobs::CreateCaseComment do
  include_context "spec helper"

  fab!(:topic) { Fabricate(:topic) }
  fab!(:_case) { Fabricate(:salesforce_case, topic: topic) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  it 'creates a case comment object on Salesforce' do
    topic.custom_fields["has_salesforce_case"] = true
    topic.save_custom_fields

    ::Salesforce::CaseComment.any_instance.expects(:create!).once
    described_class.new.execute(post_id: post.id)
  end
end
