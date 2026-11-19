# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::ConfigurationScheduler do
  include_context "with salesforce spec helper"
  include_context "with hubspot spec helper"

  fab!(:user, :verified_user)
  fab!(:group)

  [
    [
      "salesforce",
      "outbound",
      "Lead",
      Jobs::SyncSalesforceUser,
      Jobs::DiscourseCrm::SyncOutboundConfiguration,
      Jobs::SyncSalesforceUserBatch,
    ],
    [
      "hubspot",
      "outbound",
      "contact",
      Jobs::Hubspot::PushUser,
      Jobs::DiscourseCrm::SyncOutboundConfiguration,
      Jobs::Hubspot::PushUserBatch,
    ],
    [
      "hubspot",
      "inbound",
      "contact",
      Jobs::Hubspot::SyncUser,
      Jobs::Hubspot::SyncConfiguration,
      nil,
    ],
  ].each do |provider, direction, object, user_job, configuration_job, batch_job|
    context "with #{provider} #{direction} users" do
      let!(:configuration) do
        Fabricate(
          :sync_configuration,
          provider: provider,
          direction: direction,
          object: object,
          account: DiscourseCrm::SyncConfiguration.provider_definition(provider).account,
          groups: direction == "outbound" ? [group] : [],
          schedule: "hourly",
        )
      end

      before do
        group.add(user)
        user_job.clear
        configuration_job.clear
        batch_job&.clear
      end

      it "dispatches user changes only for the enabled provider and connected account" do
        DiscourseCrm::ConfigurationScheduler.enqueue_user(user, reason: "change", inbound: true)
        expect(user_job.jobs.map { |job| job["args"].first }).to contain_exactly(
          hash_including(
            "configuration_id" => configuration.id,
            "user_id" => user.id,
            "reason" => "change",
          ),
        )
        user_job.clear
        configuration.update!(account: "another-account")
        DiscourseCrm::ConfigurationScheduler.enqueue_user(user, reason: "change", inbound: true)
        expect(user_job.jobs).to be_empty

        configuration.update!(
          account: DiscourseCrm::SyncConfiguration.provider_definition(provider).account,
        )
        SiteSetting.public_send("#{provider}_enabled=", false)
        DiscourseCrm::ConfigurationScheduler.enqueue_user(user, reason: "change", inbound: true)
        expect(user_job.jobs).to be_empty
      end

      it "dispatches due configurations once to the flow's configuration job" do
        configuration.update!(last_scheduled_at: 2.hours.ago)

        DiscourseCrm::ConfigurationScheduler.enqueue_due
        DiscourseCrm::ConfigurationScheduler.enqueue_due

        expect(configuration_job.jobs.map { |job| job["args"].first }).to contain_exactly(
          hash_including("configuration_id" => configuration.id, "reason" => "scheduled"),
        )
      end

      if direction == "outbound"
        it "dispatches eligible group members to the provider's batch job" do
          Jobs::DiscourseCrm::SyncOutboundConfiguration.new.execute(
            configuration_id: configuration.id,
            reason: "backfill",
          )

          expect(batch_job.jobs.map { |job| job["args"].first }).to contain_exactly(
            hash_including(
              "configuration_id" => configuration.id,
              "user_ids" => [user.id],
              "reason" => "backfill",
            ),
          )
        end
      end
    end
  end
end
