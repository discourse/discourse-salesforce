# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe Jobs::CreateFeedItem do
  include_context "spec helper"

  fab!(:user) { Fabricate(:user) }
  fab!(:post) { Fabricate(:post, user: user) }

  it 'creates a feed item on Salesforce lead object' do
    user.custom_fields[::Salesforce::Person::LEAD_ID_FIELD] = "lead_123"
    user.save_custom_fields

    ::Salesforce::FeedItem.any_instance.expects(:create!).once
    described_class.new.execute(post_id: post.id)
  end
end
