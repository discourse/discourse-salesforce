# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::ConnectionError do
  it "logs only safe diagnostic metadata" do
    error = Salesforce::InvalidApiResponse.new("secret token and private response", status: 403)
    logger = track_log_messages { described_class.log(error, operation: "fields") }
    expect(logger.warnings).to eq(
      ["Salesforce request failed: operation=fields category=permissions status=403"],
    )
  end

  it "classifies missing credentials and invalid signing keys as authentication failures" do
    expect(described_class.category(Salesforce::InvalidCredentials.new)).to eq("authentication")
    expect(described_class.category(OpenSSL::PKey::RSAError.new)).to eq("authentication")
  end
end
