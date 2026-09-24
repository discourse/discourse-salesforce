# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "changing the Salesforce credentials" do
  include_context "with salesforce spec helper"

  it "drops the cached access token" do
    Discourse.redis.setex(::Salesforce::Api::ACCESS_TOKEN_KEY, 10.minutes, "STALE_TOKEN")

    SiteSetting.salesforce_username = "another-integration-user@example.com"

    expect(Discourse.redis.get(::Salesforce::Api::ACCESS_TOKEN_KEY)).to eq(nil)
  end

  it "ignores settings that cannot repoint the site at another org" do
    Discourse.redis.setex(::Salesforce::Api::ACCESS_TOKEN_KEY, 10.minutes, "CURRENT_TOKEN")

    SiteSetting.salesforce_case_origin = "Phone"

    expect(Discourse.redis.get(::Salesforce::Api::ACCESS_TOKEN_KEY)).to eq("CURRENT_TOKEN")
  end
end
