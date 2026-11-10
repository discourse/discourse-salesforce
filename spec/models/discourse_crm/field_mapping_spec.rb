# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::FieldMapping do
  describe "#values" do
    it "compares typed scalar values without treating blank fields as zero or false" do
      cases = [
        ["double", "42", 42, {}],
        ["double", "42.0", 42, {}],
        ["double", "0", 0, {}],
        ["boolean", "false", false, {}],
        ["boolean", "true", true, {}],
        ["double", "", 0, { "value" => 0 }],
        ["boolean", nil, false, { "value" => false }],
        ["double", "41", 42, { "value" => 42 }],
        ["boolean", "true", false, { "value" => false }],
        ["string", "042", "42", { "value" => "42" }],
      ]
      cases.each do |type, existing, incoming, expected|
        fields = [{ "name" => "value", "type" => type, "updateable" => true }]
        mapping = { "source" => "test", "destination" => "value", "policy" => "overwrite" }
        result = described_class.new([mapping], fields) { incoming }.values("value" => existing)
        expect(result).to eq(expected),
        "#{type}: #{existing.inspect} compared with #{incoming.inspect}"
      end
    end
  end
end
