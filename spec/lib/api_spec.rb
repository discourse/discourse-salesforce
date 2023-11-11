# frozen_string_literal: true

require "rails_helper"
require_relative "../spec_helper"

RSpec.describe ::Salesforce::Api do
  include_context "with salesforce spec helper"

  it "sets Salesforce access token and instance URL" do
    api = described_class.new
    expect(SiteSetting.salesforce_instance_url).to eq(instance_url)
    expect(api.access_token).to eq(access_token)
  end

  it "returns invalid credentials error when Salesforce client ID is blank" do
    SiteSetting.salesforce_client_id = ""
    expect { described_class.new }.to raise_error(::Salesforce::InvalidCredentials)
  end
end
