# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe DiscourseWorkflows::Nodes::SalesforcePersonLinked::V1, discourse_workflows: true do
  include_context "with salesforce spec helper"

  fab!(:admin)
  fab!(:user)

  def trigger_for(object_name)
    described_class.from_event(
      :salesforce_person_linked,
      user,
      object_name,
      "003000000000001AAA",
      created: true,
      acting_user: admin,
    )
  end

  describe "#matches?" do
    it "matches any object when none is selected" do
      expect(trigger_for("Contact").matches?(trigger_context({}))).to eq(true)
      expect(trigger_for("Lead").matches?(trigger_context(objects: []))).to eq(true)
    end

    it "matches only the selected objects" do
      expect(trigger_for("Contact").matches?(trigger_context(objects: ["Lead"]))).to eq(false)
      expect(trigger_for("Lead").matches?(trigger_context(objects: ["Lead"]))).to eq(true)
    end
  end

  describe "event dispatch" do
    fab!(:workflow) do
      graph =
        build_workflow_graph do |builder|
          builder.node "linked", described_class.identifier, configuration: { objects: ["Contact"] }
        end
      Fabricate(:discourse_workflows_workflow, created_by: admin, published: true, **graph)
    end

    def dispatched
      Jobs::DiscourseWorkflows::ExecuteWorkflow.jobs.map { |job| job["args"].first["trigger_data"] }
    end

    it "enqueues the workflow with output that matches the declared schema" do
      workflow
      DiscourseEvent.trigger(
        :salesforce_person_linked,
        user,
        "Contact",
        "003000000000001AAA",
        created: false,
        email_verified: true,
        acting_user: admin,
      )

      expect(dispatched.size).to eq(1)
      expect(dispatched.first).to match_node_output_schema(described_class)
      expect(dispatched.first).to include(
        "object" => "Contact",
        "id" => "003000000000001AAA",
        "created" => false,
        "email_verified" => true,
      )
      expect(dispatched.first["user"]["id"]).to eq(user.id)
      expect(dispatched.first["actor"]["id"]).to eq(admin.id)
    end

    it "stops dispatching when Salesforce is disabled" do
      workflow
      SiteSetting.salesforce_enabled = false

      DiscourseEvent.trigger(
        :salesforce_person_linked,
        user,
        "Contact",
        "003000000000001AAA",
        created: true,
        acting_user: nil,
      )

      expect(dispatched).to be_empty
    end
  end
end
