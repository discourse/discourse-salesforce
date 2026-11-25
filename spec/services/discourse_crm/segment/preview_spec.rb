# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe DiscourseCrm::Segment::Preview do
  include_context "with hubspot spec helper"

  describe described_class::Contract, type: :model do
    it { is_expected.to validate_presence_of(:conditions) }
    it { is_expected.to validate_inclusion_of(:provider).in_array(%w[salesforce hubspot]) }
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    fab!(:admin)
    fab!(:matching_user, :verified_user)
    fab!(:other_user, :verified_user)

    let(:params) do
      {
        provider: "hubspot",
        conditions: {
          all: [
            { id: 1, object: "contact", property: "jobtitle", operator: "equals", value: "cto" },
          ],
        },
      }
    end
    let(:dependencies) { { guardian: admin.guardian } }

    before do
      SiteSetting.crm_segments_enabled = true
      Fabricate(
        :hubspot_sync_configuration,
        mappings: [{ "id" => 1, "object" => "contact", "source" => "jobtitle" }],
      )
      { matching_user => "CTO", other_user => "Engineer" }.each_with_index do |(user, title), index|
        Fabricate(:crm_record, external_id: "50#{index}", data: { "jobtitle" => title })
        DiscourseCrm::RecordLink.link_many!(
          [
            {
              provider: "hubspot",
              account: "12345",
              object: "contact",
              direction: "inbound",
              user_id: user.id,
              external_id: "50#{index}",
            },
          ],
        )
      end
    end

    context "when the contract is invalid" do
      let(:params) { super().merge(provider: "pipedrive") }

      it { is_expected.to fail_a_contract }
    end

    context "when the current user is not an admin" do
      let(:dependencies) { { guardian: Fabricate(:user).guardian } }

      it { is_expected.to fail_a_policy(:can_manage) }
    end

    context "when no pull is configured" do
      before { DiscourseCrm::SyncConfiguration.delete_all }

      it { is_expected.to fail_to_find_a_model(:pulled_properties) }
    end

    context "when the conditions are malformed" do
      let(:params) { super().merge(conditions: { all: [{ object: "contact" }] }) }

      it { is_expected.to fail_with_an_invalid_model(:segment) }
    end

    context "when a condition uses a property the pull does not keep" do
      let(:params) do
        super().merge(
          conditions: {
            all: [{ id: 1, object: "company", property: "plan_tier", operator: "set" }],
          },
        )
      end

      it { is_expected.to fail_a_policy(:properties_are_pulled) }
    end

    context "when everything is ok" do
      it { is_expected.to run_successfully }

      it "reports how many linked users match without saving anything" do
        expect { result }.not_to change { DiscourseCrm::Segment.count }
        expect(result[:preview]).to eq(count: 1, total: 2, usernames: [matching_user.username])
      end
    end
  end
end
