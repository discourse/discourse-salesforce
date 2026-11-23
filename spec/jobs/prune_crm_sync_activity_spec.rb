# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Jobs::PruneCrmSyncActivity do
  fab!(:configuration, :sync_configuration)

  it "prunes attempts older than 90 days by default and supports unlimited retention" do
    freeze_time
    expired = DiscourseCrm::SyncAttempt.record(configuration, nil)
    expired.update!(created_at: 91.days.ago)
    boundary = DiscourseCrm::SyncAttempt.record(configuration, nil)
    boundary.update!(created_at: 90.days.ago)
    SiteSetting.crm_sync_activity_retention_days = 0
    described_class.new.execute({})
    expect(DiscourseCrm::SyncAttempt.count).to eq(2)

    SiteSetting.remove_override!(:crm_sync_activity_retention_days)
    described_class.new.execute({})
    expect(DiscourseCrm::SyncAttempt.pluck(:id)).to eq([boundary.id])
  end
end
