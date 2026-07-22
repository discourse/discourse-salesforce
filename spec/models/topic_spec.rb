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

    it "reflects changes to the case marker on the same topic instance" do
      topic.custom_fields.delete(CaseMixin::HAS_SALESFORCE_CASE)
      topic.save_custom_fields

      expect(topic.has_salesforce_case).to eq(false)

      topic.custom_fields[CaseMixin::HAS_SALESFORCE_CASE] = true
      topic.save_custom_fields

      expect(topic.has_salesforce_case).to eq(true)
    end
  end
end
