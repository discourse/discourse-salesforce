# frozen_string_literal: true

require 'rails_helper'
require_relative '../spec_helper'

RSpec.describe User do
  include_context "spec helper"

  fab!(:user) { Fabricate(:user) }

  describe '#create!' do
    it 'checks Salesforce objects for any existing lead/contact' do
      email = "bruce123@gmail.com"
      response_body = {}.to_json
      stub_request(:get, "#{api_path.sub("sobjects", "query")}/?q=SELECT Id FROM Contact WHERE Email = '#{email}'").
        to_return(status: 200, body: response_body, headers: {})

      user = Fabricate(:user, email: email)
    end
  end

  describe '#update' do
    it 'updates the Salesforce lead website if changed' do
      lead_id = "lead_123"
      website = "https://example.com"
      user_profile = user.user_profile
      user.salesforce_lead_id = lead_id
      user.save_custom_fields

      stub_request(:post, "#{api_path}/Lead/#{lead_id}?_HttpMethod=PATCH").
        with(body: { Website: website }.to_json).
        to_return(status: 204, headers: {})

      user_profile.website = website
      expect(user_profile.save!).to be_truthy
    end
  end
end
