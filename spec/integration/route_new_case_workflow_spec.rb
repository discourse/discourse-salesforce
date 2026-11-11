# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Workflow: Salesforce case created -> Salesforce record",
               discourse_workflows: true do
  include_context "with salesforce spec helper"

  fab!(:admin)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:first_post) { Fabricate(:post, topic: topic) }

  fab!(:routing_table) do
    Fabricate(
      :discourse_workflows_data_table,
      name: "case_routing",
      columns: [
        { "name" => "category_id", "type" => "number" },
        { "name" => "owner_team", "type" => "string" },
      ],
    )
  end

  let(:case_id) { "500000000000001AAA" }

  before do
    SiteSetting.salesforce_skip_contact_creation_on_case_sync = true

    insert_data_table_row(routing_table, "category_id" => category.id, "owner_team" => "Billing")
    insert_data_table_row(
      routing_table,
      "category_id" => category.id + 1000,
      "owner_team" => "Hardware",
    )

    stub_request(:post, "#{api_path}/Case").to_return(status: 200, body: { id: case_id }.to_json)
    stub_request(:get, "#{api_path}/Case/#{case_id}").to_return(
      status: 200,
      body: { CaseNumber: "345678", Status: "New" }.to_json,
    )
  end

  it "routes a new case using a data table" do
    graph =
      build_workflow_graph do |g|
        g.node "trigger",
               "trigger:salesforce_case_created",
               name: "Case created",
               configuration: {
                 "category_ids" => [category.id],
               }
        g.node "lookup",
               "action:data_table",
               name: "Find routing",
               configuration: {
                 "operation" => "get",
                 "data_table_id" => routing_table.id.to_s,
                 "filter" => [
                   {
                     "columnName" => "category_id",
                     "operator" => {
                       "type" => "number",
                       "operation" => "equals",
                       "singleValue" => false,
                     },
                     "value" => "={{ $trigger.topic.category_id }}",
                   },
                 ],
               }
        g.node "update",
               "action:salesforce_record",
               name: "Route case",
               configuration: {
                 "operation" => "update",
                 "object" => "Case",
                 "record_id" => "={{ $trigger.case.id }}",
                 "fields" => {
                   "values" => [
                     { "key" => "Topic_URL__c", "value" => "={{ $trigger.topic.url }}" },
                     { "key" => "Owner_Team__c", "value" => "={{ $json.owner_team }}" },
                   ],
                 },
               }
        g.chain "trigger", "lookup", "update"
      end
    Fabricate(:discourse_workflows_workflow, created_by: admin, published: true, **graph)
    update_request =
      stub_request(:patch, "#{api_path}/Case/#{case_id}").with(
        body: { Topic_URL__c: topic.url, Owner_Team__c: "Billing" }.to_json,
      ).to_return(status: 204)

    Salesforce::Case.sync!(topic, acting_user: admin)

    jobs = Jobs::DiscourseWorkflows::ExecuteWorkflow.jobs
    expect(jobs.size).to eq(1)
    Jobs::DiscourseWorkflows::ExecuteWorkflow.new.execute(jobs.first["args"].first.symbolize_keys)

    expect(DiscourseWorkflows::Execution.last.status).to eq("success")
    expect(update_request).to have_been_requested.once
  end
end
