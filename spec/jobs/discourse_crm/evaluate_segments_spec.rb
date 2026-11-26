# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Jobs::DiscourseCrm::EvaluateSegments do
  include_context "with hubspot spec helper"

  fab!(:group)
  fab!(:first_user, :verified_user)
  fab!(:second_user, :verified_user)

  let!(:configuration) do
    Fabricate(
      :hubspot_sync_configuration,
      mappings: [{ "id" => 1, "object" => "contact", "source" => "jobtitle" }],
    )
  end
  let!(:segment) do
    Fabricate(
      :crm_segment,
      configuration:,
      group_id: group.id,
      conditions: {
        "all" => [
          { "id" => 1, "object" => "contact", "property" => "jobtitle", "operator" => "set" },
        ],
      },
    )
  end

  before do
    [first_user, second_user].each_with_index do |user, index|
      Fabricate(:crm_record, external_id: "50#{index}", data: { "jobtitle" => "CTO" })
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
    described_class.clear
    SiteSetting.crm_segments_enabled = true
  end

  def enqueued_args
    described_class.jobs.map { |job| job["args"].first.except("current_site_id") }
  end

  describe "#execute" do
    it "re-enqueues itself with the cursor until the last page" do
      stub_const(DiscourseCrm::SegmentEvaluation, :PAGE_SIZE, 1) do
        described_class.new.execute(configuration_id: configuration.id)

        expect(enqueued_args).to eq(
          [{ "configuration_id" => configuration.id, "after" => first_user.id }],
        )
        expect(group.reload.users).to eq([first_user])

        2.times do
          next_args = enqueued_args.first.symbolize_keys
          described_class.clear
          described_class.new.execute(next_args)
        end

        expect(described_class.jobs).to be_empty
        expect(group.reload.users).to contain_exactly(first_user, second_user)
        expect(segment.reload.last_evaluated_at).to be_present
      end
    end

    it "evaluates only the given users without paging" do
      described_class.new.execute(configuration_id: configuration.id, user_ids: [second_user.id])

      expect(described_class.jobs).to be_empty
      expect(group.reload.users).to eq([second_user])
      expect(segment.reload.last_evaluated_at).to be_nil
    end

    it "does nothing while segments or every provider are disabled" do
      SiteSetting.crm_segments_enabled = false
      described_class.new.execute(configuration_id: configuration.id)
      expect(group.reload.users).to be_empty

      SiteSetting.crm_segments_enabled = true
      SiteSetting.hubspot_enabled = false

      described_class.new.execute(configuration_id: configuration.id)

      expect(described_class.jobs).to be_empty
      expect(group.reload.users).to be_empty
    end
  end
end
