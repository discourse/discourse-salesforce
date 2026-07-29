# frozen_string_literal: true

require_relative "../spec_helper"

describe Topic do
  describe "#has_salesforce_case" do
    fab!(:topic)

    before do
      topic.custom_fields[CaseMixin::HAS_SALESFORCE_CASE] = true
      topic.save!
    end

    it "checks the case marker when other topic custom fields are preloaded" do
      topic.reload.set_preloaded_custom_fields("another_field" => nil)

      expect(topic.has_salesforce_case).to eq(true)
    end
  end
end
