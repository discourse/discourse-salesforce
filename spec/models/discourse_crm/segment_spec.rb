# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::Segment do
  include_context "with hubspot spec helper"

  fab!(:group)

  let!(:configuration) { Fabricate(:hubspot_sync_configuration) }

  def condition(object, property, operator, value = "")
    {
      "id" => 1,
      "object" => object,
      "property" => property,
      "operator" => operator,
      "value" => value,
    }
  end

  def company_record(data)
    company = Fabricate(:crm_record, object: "company", external_id: "company-#{data.hash}", data:)
    Fabricate(:crm_record, company_external_id: company.external_id, data: { "jobtitle" => "CTO" })
  end

  describe "validations" do
    it "requires a single combinator holding complete, distinct conditions" do
      segment = Fabricate.build(:crm_segment, configuration:)
      expect(segment).to be_valid

      segment.conditions = { "all" => [], "any" => [] }
      expect(segment).to be_invalid
      segment.conditions = { "both" => [condition("contact", "jobtitle", "equals", "CTO")] }
      expect(segment).to be_invalid
      segment.conditions = { "all" => [] }
      expect(segment).to be_invalid
      segment.conditions = { "all" => [condition("contact", "jobtitle", "equals")] }
      expect(segment).to be_invalid
      segment.conditions = { "all" => [condition("contact", "jobtitle", "between", "1")] }
      expect(segment).to be_invalid
      segment.conditions = {
        "all" => [
          condition("contact", "jobtitle", "set"),
          condition("contact", "jobtitle", "set").merge("id" => 2),
        ],
      }
      expect(segment).to be_invalid
      segment.conditions = {
        "all" => [condition("contact", "jobtitle", "set").merge("extra" => 1)],
      }
      expect(segment).to be_invalid
      segment.conditions = { "all" => ["jobtitle is set"] }
      expect(segment).to be_invalid
      expect(segment.errors.full_messages).to eq(
        ["Conditions must have at least one complete condition"],
      )
      segment.conditions = { "all" => [condition("contact", "jobtitle", "equals", 5)] }
      expect(segment).to be_invalid
      segment.conditions = { "all" => [condition("contact", "jobtitle", "set").merge("id" => "1")] }
      expect(segment).to be_invalid
      segment.conditions = { any: [condition("contact", "jobtitle", "not_set")] }
      expect(segment).to be_valid
      expect(segment.conditions.keys).to eq(["any"])
    end

    it "belongs to a pull configuration" do
      segment = Fabricate.build(:crm_segment, configuration: nil)
      expect(segment).to be_invalid

      segment.configuration = Fabricate(:sync_configuration)
      expect(segment).to be_invalid
      expect(segment.errors.full_messages).to eq(["Configuration must be a pull configuration"])

      segment.configuration = configuration
      expect(segment).to be_valid
    end

    it "accepts only an existing non-automatic group that no other segment targets" do
      segment =
        Fabricate.build(:crm_segment, configuration:, group_id: Group::AUTO_GROUPS[:trust_level_1])
      expect(segment).to be_invalid
      segment.group_id = -1
      expect(segment).to be_invalid
      segment.group_id = nil
      segment.remove_unmatched = true
      expect(segment).to be_invalid
      segment.group_id = group.id
      expect(segment).to be_valid
      segment.save!

      competitor = Fabricate.build(:crm_segment, configuration:, name: "Other", group_id: group.id)
      expect(competitor).to be_invalid
      expect(competitor.errors.full_messages).to eq(
        ["Group is already targeted by another segment"],
      )
    end
  end

  describe "#missing_properties" do
    it "lists condition properties the pull does not keep" do
      segment =
        Fabricate.build(
          :crm_segment,
          configuration:,
          conditions: {
            "all" => [
              condition("company", "plan_tier", "set"),
              condition("contact", "jobtitle", "set").merge("id" => 2),
            ],
          },
        )

      expect(segment.missing_properties([{ object: "company", name: "plan_tier" }])).to eq(
        ["contact.jobtitle"],
      )
    end
  end

  describe "#matches?" do
    it "compares case-insensitively and treats null as blank and a missing key as unknown" do
      enterprise = company_record("plan_tier" => "Enterprise Plus", "churned_" => nil)
      churned = company_record("plan_tier" => "enterprise", "churned_" => "Yes")
      never_fetched = company_record("plan_tier" => "Enterprise")
      no_company = Fabricate(:crm_record, data: { "jobtitle" => "CTO" })
      segment =
        Fabricate.build(
          :crm_segment,
          configuration:,
          conditions: {
            "all" => [
              condition("company", "plan_tier", "contains", "ENTERPRISE"),
              condition("company", "churned_", "not_equals", "yes").merge("id" => 2),
            ],
          },
        )

      expect(segment.matches?([enterprise])).to eq(true)
      expect(segment.matches?([churned])).to eq(false)
      expect(segment.matches?([never_fetched])).to eq(false)
      expect(segment.matches?([no_company])).to eq(false)
      expect(segment.matches?([churned, enterprise])).to eq(true)
      expect(segment.matches?([])).to eq(false)
    end

    it "evaluates every operator against blank, filled and unknown values" do
      blank = company_record("industry" => nil)
      filled = company_record("industry" => "Software")
      unknown = company_record("name" => "Acme")
      results =
        described_class::OPERATORS.to_h do |operator|
          segment =
            Fabricate.build(
              :crm_segment,
              configuration:,
              conditions: {
                "all" => [condition("company", "industry", operator, "soft")],
              },
            )
          [operator, [blank, filled, unknown].map { |record| segment.matches?([record]) }]
        end

      expect(results).to eq(
        "equals" => [false, false, false],
        "not_equals" => [true, true, false],
        "contains" => [false, true, false],
        "not_contains" => [true, false, false],
        "set" => [false, true, false],
        "not_set" => [true, false, false],
      )
    end

    it "requires every condition with all and one condition with any" do
      record = company_record("plan_tier" => "Enterprise", "industry" => "Finance")
      conditions = [
        condition("company", "plan_tier", "equals", "enterprise"),
        condition("company", "industry", "equals", "software").merge("id" => 2),
      ]

      expect(
        Fabricate.build(:crm_segment, configuration:, conditions: { "all" => conditions }).matches?(
          [record],
        ),
      ).to eq(false)
      expect(
        Fabricate.build(:crm_segment, configuration:, conditions: { "any" => conditions }).matches?(
          [record],
        ),
      ).to eq(true)
    end
  end
end
