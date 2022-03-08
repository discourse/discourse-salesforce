# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe Jobs::SyncCaseComments do
  include_context "spec helper"

  fab!(:topic) { Fabricate(:topic) }
  fab!(:_case) { Fabricate(:salesforce_case, topic: topic) }
  fab!(:post) { Fabricate(:post, topic: topic) }
  fab!(:post2) { Fabricate(:post, topic: topic, post_number: 2) }
  fab!(:post3) { Fabricate(:post, topic: topic, post_number: 3) }

  it 'creates multiple case comment objects on Salesforce' do
    topic.custom_fields["has_salesforce_case"] = true
    topic.save!

    ::Salesforce::CaseComment.any_instance.expects(:create!).twice

    described_class.new.execute(topic_id: topic.id)
  end
end
