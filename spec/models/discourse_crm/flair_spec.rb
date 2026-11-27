# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::Flair do
  include_context "with hubspot spec helper"

  fab!(:viewers, :group)
  fab!(:viewer) { Fabricate(:user, groups: [viewers]) }
  fab!(:outsider, :user)
  fab!(:lead_user, :verified_user)
  fab!(:customer_user, :verified_user)

  let!(:configuration) do
    Fabricate(
      :hubspot_sync_configuration,
      mappings: [
        { "id" => 1, "object" => "contact", "source" => "lifecyclestage" },
        { "id" => 2, "object" => "contact", "source" => "jobtitle" },
        { "id" => 3, "object" => "company", "source" => "plan_tier" },
      ],
      property_metadata: {
        "contact" => {
          "lifecyclestage" => {
            "label" => "Lifecycle stage",
            "options" => {
              "lead" => "Lead",
            },
          },
        },
        "company" => {
          "plan_tier" => {
            "label" => "Plan tier",
            "options" => {
            },
          },
        },
      },
    )
  end
  let!(:segment) do
    Fabricate(
      :crm_segment,
      configuration:,
      name: "Enterprise",
      flair_enabled: true,
      flair_text_property: "contact.lifecyclestage",
      flair_properties: %w[contact.lifecyclestage company.plan_tier contact.jobtitle],
      flair_group_ids: [viewers.id],
    )
  end

  before do
    SiteSetting.crm_segments_enabled = true
    Fabricate(
      :crm_record,
      object: "company",
      external_id: "acme",
      data: {
        "plan_tier" => "Enterprise",
      },
    )
    link(lead_user, "501", company: "acme", data: { "lifecyclestage" => "lead", "jobtitle" => "" })
    link(customer_user, "502", company: "acme", data: { "lifecyclestage" => "customer" })
    segment.members.create!(user: lead_user)
    segment.members.create!(user: customer_user)
  end

  def link(user, external_id, company:, data:)
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

  def flairs(user, user_ids = [lead_user.id, customer_user.id])
    described_class.for_users(user_ids, guardian: user&.guardian || Guardian.new)
  end

  describe ".for_users" do
    it "builds a flair for members of the segments the viewer may see" do
      expect(flairs(viewer)).to eq(
        lead_user.id => {
          provider: "hubspot",
          icon: "fab-hubspot",
          text: "Lead",
          properties: [
            { label: "Lifecycle stage", value: "Lead" },
            { label: "Plan tier", value: "Enterprise" },
          ],
          url: "https://app.hubspot.com/contacts/12345/record/0-1/501",
        },
        customer_user.id => {
          provider: "hubspot",
          icon: "fab-hubspot",
          text: "customer",
          properties: [
            { label: "Lifecycle stage", value: "customer" },
            { label: "Plan tier", value: "Enterprise" },
          ],
          url: "https://app.hubspot.com/contacts/12345/record/0-1/502",
        },
      )
    end

    it "shows nothing to viewers outside the flair groups, anonymous viewers and non-members" do
      expect(flairs(outsider)).to be_empty
      expect(flairs(nil)).to be_empty
      expect(flairs(viewer, [outsider.id])).to be_empty
    end

    it "shows a flair without groups to everyone, including anonymous viewers" do
      segment.update!(flair_group_ids: [])

      expect(flairs(outsider).keys).to contain_exactly(lead_user.id, customer_user.id)
      expect(flairs(nil).keys).to contain_exactly(lead_user.id, customer_user.id)
    end

    it "shows a flair whose only group was deleted to nobody" do
      viewers.destroy!

      expect(flairs(viewer.reload)).to be_empty
      expect(flairs(nil)).to be_empty
    end

    it "leaves out properties the pull no longer keeps" do
      configuration.update!(
        mappings: [{ "id" => 3, "object" => "company", "source" => "plan_tier" }],
      )

      expect(flairs(viewer)[lead_user.id]).to include(
        text: "Enterprise",
        properties: [{ label: "Plan tier", value: "Enterprise" }],
      )
    end

    it "clears the flair of an anonymized user" do
      UserAnonymizer.make_anonymous(lead_user, Fabricate(:admin))

      expect(flairs(viewer).keys).to eq([customer_user.id])
      expect(DiscourseCrm::RecordLink.where(user_id: lead_user.id)).to be_empty
    end

    it "honours automatic groups and ignores the flair while it is off or segments are disabled" do
      segment.update!(flair_group_ids: [Group::AUTO_GROUPS[:trust_level_0]])
      Group.user_trust_level_change!(outsider.id, outsider.trust_level)
      expect(flairs(outsider).keys).to contain_exactly(lead_user.id, customer_user.id)

      segment.update!(flair_enabled: false)
      expect(flairs(outsider)).to be_empty

      segment.update!(flair_enabled: true)
      SiteSetting.crm_segments_enabled = false
      expect(flairs(outsider)).to be_empty
    end

    it "uses the lowest segment a user belongs to and skips inactive configurations" do
      other =
        Fabricate(
          :crm_segment,
          configuration:,
          name: "Everyone",
          flair_enabled: true,
          flair_group_ids: [viewers.id],
        )
      other.members.create!(user: lead_user)

      expect(flairs(viewer)[lead_user.id][:text]).to eq("Lead")

      segment.destroy!
      expect(flairs(viewer)[lead_user.id][:text]).to eq("Everyone")

      configuration.update_columns(account: "99999")
      expect(flairs(viewer)).to be_empty
    end
  end

  describe ".build" do
    it "falls back to the segment name without a text property or value and prefers a matching record" do
      segment.update!(flair_text_property: nil)
      expect(described_class.build(segment, lead_user.crm_records.to_a)[:text]).to eq("Enterprise")

      segment.update!(flair_text_property: "contact.jobtitle")
      expect(described_class.build(segment, lead_user.crm_records.to_a)[:text]).to eq("Enterprise")

      segment.update!(
        flair_text_property: "contact.lifecyclestage",
        conditions: {
          "all" => [
            {
              "id" => 1,
              "object" => "contact",
              "property" => "lifecyclestage",
              "operator" => "equals",
              "value" => "customer",
            },
          ],
        },
      )
      records = lead_user.crm_records.to_a + customer_user.crm_records.to_a
      expect(described_class.build(segment, records)[:text]).to eq("customer")
      expect(described_class.build(segment, [])).to be_nil
    end
  end
end
