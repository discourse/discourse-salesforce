# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe DiscourseCrm::Segment::Update do
  include_context "with hubspot spec helper"

  describe described_class::Contract, type: :model do
    it { is_expected.to validate_presence_of(:segment_id) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(60) }
    it { is_expected.to validate_presence_of(:conditions) }
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    fab!(:admin)
    fab!(:old_group, :group)
    fab!(:new_group, :group)
    fab!(:member, :verified_user)

    let!(:configuration) do
      Fabricate(
        :hubspot_sync_configuration,
        mappings: [{ "id" => 1, "object" => "company", "source" => "plan_tier" }],
      )
    end
    let!(:segment) do
      Fabricate(
        :crm_segment,
        configuration:,
        group_id: old_group.id,
        remove_unmatched: true,
        last_evaluated_at: 1.hour.ago,
      )
    end
    let(:params) do
      {
        segment_id: segment.id,
        name: "Renamed",
        conditions: {
          any: [{ id: 1, object: "company", property: "plan_tier", operator: "set" }],
        },
        group_id: new_group.id,
        remove_unmatched: false,
      }
    end
    let(:dependencies) { { guardian: admin.guardian } }

    before do
      segment.members.create!(user: member)
      old_group.add(member)
      Jobs::DiscourseCrm::EvaluateSegments.clear
      SiteSetting.crm_segments_enabled = true
    end

    context "when the contract is invalid" do
      let(:params) { super().merge(conditions: nil) }

      it { is_expected.to fail_a_contract }
    end

    context "when the current user is not an admin" do
      let(:dependencies) { { guardian: Fabricate(:user).guardian } }

      it { is_expected.to fail_a_policy(:can_manage) }
    end

    context "when the segment does not exist" do
      let(:params) { super().merge(segment_id: -1) }

      it { is_expected.to fail_to_find_a_model(:segment) }
    end

    context "when the changes make the segment invalid" do
      let(:params) { super().merge(conditions: { all: [] }) }

      it { is_expected.to fail_with_an_invalid_model(:segment) }
    end

    context "when a condition uses a property the pull does not keep" do
      let(:params) do
        super().merge(
          conditions: {
            all: [{ id: 1, object: "contact", property: "jobtitle", operator: "set" }],
          },
        )
      end

      it { is_expected.to fail_a_policy(:properties_are_pulled) }
    end

    context "when the flair group ids are not integers" do
      let(:params) { super().merge(flair_group_ids: ["abc"]) }

      it { is_expected.to fail_a_contract }
    end

    context "when the flair properties are not strings" do
      let(:params) { super().merge(flair_properties: ["1"]) }

      it { is_expected.to fail_a_contract }
    end

    context "when the flair uses a property the pull does not keep" do
      let(:params) do
        super().merge(
          flair_enabled: true,
          flair_group_ids: [new_group.id],
          flair_properties: ["contact.jobtitle"],
        )
      end

      it { is_expected.to fail_a_policy(:properties_are_pulled) }
    end

    context "when everything is ok" do
      it { is_expected.to run_successfully }

      it "saves the changes, keeps the old group's members and enqueues an evaluation" do
        result

        expect(segment.reload).to have_attributes(
          configuration:,
          name: "Renamed",
          group_id: new_group.id,
          remove_unmatched: false,
          last_evaluated_at: nil,
          conditions: {
            "any" => [
              { "id" => 1, "object" => "company", "property" => "plan_tier", "operator" => "set" },
            ],
          },
        )
        expect(old_group.reload.users).to eq([member])
        expect(
          Jobs::DiscourseCrm::EvaluateSegments.jobs.map { |job| job["args"].first },
        ).to contain_exactly(hash_including("configuration_id" => configuration.id))
      end
    end
  end
end
