# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::ConfiguredUserSync do
  let(:fields) do
    %w[Email LastName Company].map do |name|
      { "name" => name, "type" => "string", "createable" => true, "updateable" => true }
    end
  end

  def configuration(object, destinations)
    {
      "object" => object,
      "mappings" =>
        destinations.map do |destination|
          { "source" => "last", "destination" => destination, "policy" => "keep" }
        end,
    }
  end

  it "requires the Lead mapping fields" do
    expect {
      described_class.validate_mappings!(configuration("Lead", %w[LastName Company]), fields)
    }.not_to raise_error
    [%w[LastName], %w[Company]].each do |destinations|
      expect {
        described_class.validate_mappings!(configuration("Lead", destinations), fields)
      }.to raise_error(Discourse::InvalidParameters)
    end
  end

  it "requires LastName for Contacts without requiring Company" do
    expect {
      described_class.validate_mappings!(configuration("Contact", %w[LastName]), fields)
    }.not_to raise_error
    expect {
      described_class.validate_mappings!(configuration("Contact", %w[Company]), fields)
    }.to raise_error(Discourse::InvalidParameters)
  end

  it "keeps Email automatic and requires it to be createable" do
    expect {
      described_class.validate_mappings!(configuration("Contact", %w[LastName Email]), fields)
    }.to raise_error(Discourse::InvalidParameters)
    fields.first["createable"] = false
    expect {
      described_class.validate_mappings!(configuration("Contact", %w[LastName]), fields)
    }.to raise_error(Discourse::InvalidParameters)
  end

  it "rejects unsupported object names instead of treating them as Contacts" do
    expect {
      described_class.validate_mappings!(configuration("Account", %w[LastName]), fields)
    }.to raise_error(Discourse::InvalidParameters)
    expect { described_class.new({ "object" => "Account" }, nil) }.to raise_error(
      Discourse::InvalidParameters,
    )
  end
end
