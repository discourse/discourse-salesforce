# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe User do
  include_context "with salesforce spec helper"

  describe "#on_create" do
    it "syncs user to Salesforce" do
      user = Fabricate.build(:user)
      user.save!

      job_args = Jobs::SyncSalesforceUser.jobs.last["args"].first
      expect(job_args["user_id"]).to eq(user.id)
    end
  end
end
