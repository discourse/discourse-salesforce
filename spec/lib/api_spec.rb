# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe ::Salesforce::Api do
  include_context "salesforce spec helper"

  it "sets Salesforce access token and instance URL" do
    api = described_class.new
    expect(SiteSetting.salesforce_instance_url).to eq(instance_url)
    expect(api.access_token).to eq(access_token)
  end
end
