# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe DiscourseCrm::Segment::Destroy do
  include_context "with hubspot spec helper"

  describe described_class::Contract, type: :model do
    it { is_expected.to validate_presence_of(:segment_id) }
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    fab!(:admin)
    fab!(:group)
    fab!(:member, :verified_user)

    let!(:configuration) { Fabricate(:hubspot_sync_configuration) }
    let!(:segment) do
      Fabricate(:crm_segment, configuration:, group_id: group.id, remove_unmatched: true)
    end
    let(:params) { { segment_id: segment.id } }
    let(:dependencies) { { guardian: admin.guardian } }

    before do
      SiteSetting.crm_segments_enabled = true
      segment.members.create!(user: member)
      group.add(member)
    end

    context "when the contract is invalid" do
      let(:params) { { segment_id: nil } }

      it { is_expected.to fail_a_contract }
    end

    context "when the current user is not an admin" do
      let(:dependencies) { { guardian: Fabricate(:user).guardian } }

      it { is_expected.to fail_a_policy(:can_manage) }
    end

    context "when the segment does not exist" do
      let(:params) { { segment_id: -1 } }

      it { is_expected.to fail_to_find_a_model(:segment) }
    end

    context "when everything is ok" do
      it { is_expected.to run_successfully }

      it "deletes the segment and its members but keeps the group's members" do
        expect { result }.to change { DiscourseCrm::Segment.count }.by(-1).and change {
                DiscourseCrm::SegmentMember.count
              }.by(-1)
        expect(group.reload.users).to eq([member])
      end
    end
  end
end
