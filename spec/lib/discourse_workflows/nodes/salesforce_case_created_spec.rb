# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe DiscourseWorkflows::Nodes::SalesforceCaseCreated::V1, discourse_workflows: true do
  include_context "with salesforce spec helper"

  fab!(:admin)
  fab!(:category)
  fab!(:other_category, :category)
  fab!(:tag)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:salesforce_case) { Fabricate(:salesforce_case, topic: topic, uid: "500000000000001AAA") }

  before { SiteSetting.tagging_enabled = true }

  describe "#matches?" do
    it "filters by category and tag" do
      topic.tags << tag
      trigger = described_class.from_event(:salesforce_case_created, salesforce_case)

      expect(trigger.matches?(trigger_context({}))).to eq(true)
      expect(trigger.matches?(trigger_context(category_ids: [other_category.id]))).to eq(false)
      expect(trigger.matches?(trigger_context(tag_names: ["missing"]))).to eq(false)
      expect(
        trigger.matches?(trigger_context(category_ids: [category.id], tag_names: [tag.name])),
      ).to eq(true)
    end
  end

  describe "event dispatch" do
    fab!(:workflow) do
      graph = build_workflow_graph { |builder| builder.node "case", described_class.identifier }
      Fabricate(:discourse_workflows_workflow, created_by: admin, published: true, **graph)
    end

    def dispatched
      Jobs::DiscourseWorkflows::ExecuteWorkflow.jobs.map { |job| job["args"].first["trigger_data"] }
    end

    it "enqueues the workflow with output that matches the declared schema" do
      workflow
      DiscourseEvent.trigger(:salesforce_case_created, salesforce_case, acting_user: admin)

      expect(dispatched.size).to eq(1)
      data = dispatched.first
      expect(data).to match_node_output_schema(described_class)
      expect(data["case"]).to eq(
        "id" => "500000000000001AAA",
        "number" => "345678",
        "status" => "New",
      )
      expect(data["topic"]).to include("id" => topic.id, "url" => topic.url)
      expect(data["user"]["id"]).to eq(topic.user_id)
      expect(data["actor"]["id"]).to eq(admin.id)
    end

    it "stops dispatching when Salesforce is disabled" do
      workflow
      SiteSetting.salesforce_enabled = false

      DiscourseEvent.trigger(:salesforce_case_created, salesforce_case, acting_user: admin)

      expect(dispatched).to be_empty
    end
  end
end
