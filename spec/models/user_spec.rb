# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe User do
  include_context "with salesforce spec helper"

  describe "user creation" do
    it "enqueues the legacy Salesforce job for a new user" do
      user = Fabricate.build(:user)
      user.save!

      job_args = Jobs::SyncSalesforceUser.jobs.last["args"].first
      expect(job_args["user_id"]).to eq(user.id)
    end

    it "enqueues the legacy Salesforce job for a staged user" do
      user = Fabricate(:user, staged: true, active: false)

      job_args = Jobs::SyncSalesforceUser.jobs.last["args"].first
      expect(job_args["user_id"]).to eq(user.id)
    end
  end
end
