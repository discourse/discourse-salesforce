# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe DiscourseCrm::OutboundSyncActivity do
  fab!(:user)

  shared_examples "an outbound activity recorder" do
    it "keeps the failed attempt when a retry updates the user's CRM record" do
      activity.record_failure(configuration, user.id, StandardError.new)
      activity.record_write(configuration, user.id, created: false, changed: true)

      attempts =
        DiscourseCrm::SyncAttempt.where(configuration_id: configuration.id, user_id: user.id)
      expect(attempts.order(:id).pluck(:outcome, :reason)).to eq(
        [%w[failed failed], %w[success updated]],
      )
    end
  end

  context "with Salesforce" do
    let(:activity) { Salesforce::SyncActivity }
    fab!(:configuration, :sync_configuration)

    include_examples "an outbound activity recorder"
  end

  context "with HubSpot" do
    let(:activity) { Hubspot::SyncActivity }
    fab!(:configuration) do
      Fabricate(
        :sync_configuration,
        provider: "hubspot",
        account: "12345",
        object: "contact",
        mappings: [{ "source" => "last", "destination" => "lastname", "policy" => "keep" }],
      )
    end

    include_examples "an outbound activity recorder"
  end
end
