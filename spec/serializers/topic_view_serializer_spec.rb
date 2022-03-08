# frozen_string_literal: true

require "rails_helper"
require_relative '../spec_helper'

describe TopicViewSerializer do
  include_context "spec helper"

  fab!(:topic) { Fabricate(:topic) }
  fab!(:_case) { Fabricate(:salesforce_case, topic: topic) }
  fab!(:post) { Fabricate(:post, topic: topic) }
  fab!(:admin) { Fabricate(:admin) }

  it "includes Salesforce case details" do
    topic_view = TopicView.new(topic.id, admin)
    topic.custom_fields["has_salesforce_case"] = true
    topic.save!

    json = described_class.new(topic_view, scope: Guardian.new(admin), root: false).as_json

    expect(json[:salesforce_case][:id]).to eq(_case.id)
  end
end
