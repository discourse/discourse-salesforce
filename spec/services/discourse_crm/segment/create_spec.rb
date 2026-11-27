# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe DiscourseCrm::Segment::Create do
  include_context "with hubspot spec helper"

  describe described_class::Contract, type: :model do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(60) }
    it { is_expected.to validate_presence_of(:conditions) }
    it { is_expected.to validate_presence_of(:configuration_id) }
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    fab!(:admin)
    fab!(:group)

    let!(:configuration) do
      Fabricate(
        :hubspot_sync_configuration,
        mappings: [{ "id" => 1, "object" => "company", "source" => "plan_tier" }],
      )
    end
    let(:params) do
      {
        configuration_id: configuration.id,
        name: " Enterprise customers ",
        conditions: {
          all: [
            {
              id: 1,
              object: "company",
              property: "plan_tier",
              operator: "contains",
              value: "enterprise",
            },
          ],
        },
        group_id: group.id,
        remove_unmatched: true,
        flair_enabled: true,
        flair_text_property: "company.plan_tier",
        flair_properties: ["company.plan_tier"],
        flair_group_ids: [group.id],
      }
    end
    let(:dependencies) { { guardian: admin.guardian } }

    before do
      Jobs::DiscourseCrm::EvaluateSegments.clear
      SiteSetting.crm_segments_enabled = true
    end

    context "when the contract is invalid" do
      let(:params) { super().merge(name: "") }

      it { is_expected.to fail_a_contract }
    end

    context "when segments are disabled" do
      before { SiteSetting.crm_segments_enabled = false }

      it { is_expected.to fail_a_policy(:can_manage) }
    end

    context "when the current user is not an admin" do
      let(:dependencies) { { guardian: Fabricate(:user).guardian } }

      it { is_expected.to fail_a_policy(:can_manage) }
    end

    context "when the configuration is not an active pull" do
      let(:params) { super().merge(configuration_id: Fabricate(:sync_configuration).id) }

      it { is_expected.to fail_to_find_a_model(:configuration) }
    end

    context "when the pull keeps no properties" do
      before { configuration.update_columns(mappings: []) }

      it { is_expected.to fail_to_find_a_model(:pulled_properties) }
    end

    context "when the segment is invalid" do
      let(:params) { super().merge(group_id: Group::AUTO_GROUPS[:staff]) }

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
          flair_group_ids: [group.id],
          flair_properties: ["contact.jobtitle"],
        )
      end

      it { is_expected.to fail_a_policy(:properties_are_pulled) }
    end

    context "when everything is ok" do
      it { is_expected.to run_successfully }

      it "creates the segment on the pull configuration and enqueues its evaluation" do
        expect { result }.to change { DiscourseCrm::Segment.count }.by(1)
        expect(result[:segment]).to have_attributes(
          configuration:,
          name: "Enterprise customers",
          group_id: group.id,
          remove_unmatched: true,
          flair_enabled: true,
          flair_text_property: "company.plan_tier",
          flair_properties: ["company.plan_tier"],
          flair_group_ids: [group.id],
          conditions: {
            "all" => [
              {
                "id" => 1,
                "object" => "company",
                "property" => "plan_tier",
                "operator" => "contains",
                "value" => "enterprise",
              },
            ],
          },
        )
        expect(
          Jobs::DiscourseCrm::EvaluateSegments.jobs.map { |job| job["args"].first },
        ).to contain_exactly(hash_including("configuration_id" => configuration.id))
      end
    end

    context "when the flair is off" do
      let(:params) { super().merge(flair_enabled: false) }

      it "stores no flair text or tooltip properties" do
        expect(result[:segment]).to have_attributes(
          flair_enabled: false,
          flair_text_property: nil,
          flair_properties: [],
          flair_group_ids: [group.id],
        )
      end
    end
  end
end
