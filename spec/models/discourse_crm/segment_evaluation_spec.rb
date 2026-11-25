# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::SegmentEvaluation do
  include_context "with hubspot spec helper"

  fab!(:group)
  fab!(:enterprise_user, :verified_user)
  fab!(:business_user, :verified_user)
  fab!(:manual_user, :verified_user)

  let!(:configuration) do
    Fabricate(
      :hubspot_sync_configuration,
      mappings: [
        { "id" => 1, "object" => "contact", "source" => "jobtitle" },
        { "id" => 2, "object" => "company", "source" => "plan_tier" },
      ],
    )
  end

  before do
    company("acme", "plan_tier" => "Enterprise")
    company("initech", "plan_tier" => "Business")
    link(enterprise_user, "501", company: "acme")
    link(business_user, "502", company: "initech")
  end

  def company(external_id, data)
    Fabricate(:crm_record, object: "company", external_id:, data:)
  end

  def link(user, external_id, company: nil, data: { "jobtitle" => "CTO" })
    Fabricate(:crm_record, external_id:, company_external_id: company, data:)
    DiscourseCrm::RecordLink.link_many!(
      [
        {
          provider: "hubspot",
          account: "12345",
          object: "contact",
          direction: "inbound",
          user_id: user.id,
          external_id:,
        },
      ],
    )
  end

  def run_all
    after = nil
    loop do
      after = described_class.run_page(provider: "hubspot", account: "12345", after:)
      break if after.nil?
    end
  end

  describe ".run_page" do
    it "stops before loading any user when no segment can be evaluated" do
      stub_const(described_class, :PAGE_SIZE, 1) do
        expect(described_class.run_page(provider: "hubspot", account: "12345")).to be_nil

        configuration.update!(
          mappings: [{ "id" => 1, "object" => "contact", "source" => "jobtitle" }],
        )
        Fabricate(:crm_segment, group_id: group.id)

        expect(described_class.run_page(provider: "hubspot", account: "12345")).to be_nil
        expect(group.reload.users).to be_empty
      end
    end

    it "pages through linked users with the cursor and finishes on a short page" do
      stub_const(described_class, :PAGE_SIZE, 1) do
        segment = Fabricate(:crm_segment, group_id: group.id)

        first = described_class.run_page(provider: "hubspot", account: "12345")
        expect(first).to eq(enterprise_user.id)
        expect(segment.reload.last_evaluated_at).to be_nil

        second = described_class.run_page(provider: "hubspot", account: "12345", after: first)
        expect(second).to eq(business_user.id)

        third = described_class.run_page(provider: "hubspot", account: "12345", after: second)
        expect(third).to be_nil
        expect(segment.reload.last_evaluated_at).to be_present
        expect(segment.members.pluck(:user_id)).to eq([enterprise_user.id])
        expect(group.users).to eq([enterprise_user])
      end
    end

    it "only adds users unless the segment removes unmatched users" do
      adding = Fabricate(:crm_segment, group_id: group.id)
      group.add(manual_user)
      group.add(business_user)

      run_all

      expect(group.reload.users).to contain_exactly(enterprise_user, business_user, manual_user)

      adding.update!(remove_unmatched: true)
      run_all

      expect(group.reload.users).to eq([enterprise_user])
    end

    it "drops members whose link is gone and leaves users who are no longer eligible out" do
      segment = Fabricate(:crm_segment, group_id: group.id, remove_unmatched: true)
      run_all
      expect(group.reload.users).to eq([enterprise_user])

      DiscourseCrm::RecordLink.where(user_id: enterprise_user.id).delete_all
      link(manual_user, "503", company: "acme")
      manual_user.update!(suspended_till: 1.year.from_now, suspended_at: Time.zone.now)
      run_all

      expect(segment.reload.members).to be_empty
      expect(group.reload.users).to be_empty
    end

    it "skips a segment whose property is no longer pulled and leaves its group alone" do
      segment = Fabricate(:crm_segment, group_id: group.id, remove_unmatched: true)
      group.add(manual_user)
      configuration.update!(
        mappings: [{ "id" => 1, "object" => "contact", "source" => "jobtitle" }],
      )

      run_all

      expect(segment.reload.last_evaluated_at).to be_nil
      expect(segment.members).to be_empty
      expect(group.reload.users).to eq([manual_user])
    end
  end

  describe ".run_for_users" do
    it "updates only the given users" do
      segment = Fabricate(:crm_segment, group_id: group.id, remove_unmatched: true)
      group.add(business_user)

      described_class.run_for_users(
        provider: "hubspot",
        account: "12345",
        user_ids: [enterprise_user.id],
      )

      expect(segment.reload.members.pluck(:user_id)).to eq([enterprise_user.id])
      expect(segment.last_evaluated_at).to be_nil
      expect(group.reload.users).to contain_exactly(enterprise_user, business_user)
    end
  end

  describe ".preview" do
    it "counts matching eligible users and names the first of them" do
      link(manual_user, "503", company: "acme")
      manual_user.update!(active: false)
      segment = Fabricate.build(:crm_segment)

      expect(described_class.preview(segment)).to eq(
        count: 1,
        total: 2,
        usernames: [enterprise_user.username],
      )
    end
  end
end
