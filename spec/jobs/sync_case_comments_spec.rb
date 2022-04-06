# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe Jobs::SyncCaseComments do
  include_context "spec helper"

  fab!(:topic) { Fabricate(:topic) }
  fab!(:salesforce_case) { Fabricate(:salesforce_case, topic: topic) }
  fab!(:post) { Fabricate(:post, topic: topic) }
  fab!(:post2) { Fabricate(:post, topic: topic, post_number: 2) }
  fab!(:post3) { Fabricate(:post, topic: topic, post_number: 3) }
  fab!(:post4) { Fabricate(:post, topic: topic, post_number: 4) }

  it 'will not create comments if topic not linked to Salesforce case' do
    salesforce_case.destroy!
    ::Salesforce::CaseComment.any_instance.expects(:create!).never
    described_class.new.execute(topic_id: topic.id)
  end

  it 'creates multiple case comment objects on Salesforce' do
    topic.custom_fields["has_salesforce_case"] = true
    topic.save_custom_fields

    post4.custom_fields[::Salesforce::CaseComment::ID_FIELD] = "case_123"
    post4.save_custom_fields

    ::Salesforce::CaseComment.any_instance.expects(:create!).twice

    described_class.new.execute(topic_id: topic.id)
  end
end
