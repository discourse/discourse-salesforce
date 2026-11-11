# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Workflow: Salesforce contact or lead linked -> Salesforce record",
               discourse_workflows: true do
  include_context "with salesforce spec helper"

  fab!(:admin)
  fab!(:user, :verified_user)

  let(:contact_id) { "003000000000001AAA" }
  let(:contact_path) { "#{api_path}/Contact/#{contact_id}" }
  let(:profile_url) { "#{Discourse.base_url}/u/#{user.username}" }

  fab!(:workflow) do
    graph =
      build_workflow_graph do |g|
        g.node "trigger",
               "trigger:salesforce_person_linked",
               name: "Contact linked",
               configuration: {
                 "objects" => ["Contact"],
               }
        g.node "existing",
               "condition:if",
               name: "Existing contact with a verified email",
               configuration: {
                 "combinator" => "and",
                 "conditions" => [
                   {
                     "id" => "1",
                     "leftValue" => "={{ $trigger.created }}",
                     "operator" => {
                       "type" => "boolean",
                       "operation" => "false",
                       "singleValue" => true,
                     },
                   },
                   {
                     "id" => "2",
                     "leftValue" => "={{ $trigger.email_verified }}",
                     "operator" => {
                       "type" => "boolean",
                       "operation" => "true",
                       "singleValue" => true,
                     },
                   },
                 ],
               }
        g.node "get",
               "action:salesforce_record",
               name: "Get contact",
               configuration: {
                 "operation" => "get",
                 "object" => "Contact",
                 "record_id" => "={{ $trigger.id }}",
                 "field_names" => "Description",
               }
        g.node "missing_url",
               "condition:if",
               name: "Profile URL not there yet",
               configuration: {
                 "combinator" => "and",
                 "conditions" => [
                   {
                     "id" => "1",
                     "leftValue" => "={{ $json.record.Description || '' }}",
                     "rightValue" => "={{ $helpers.absoluteUrl('/u/' + $trigger.user.username) }}",
                     "operator" => {
                       "type" => "string",
                       "operation" => "notContains",
                     },
                   },
                 ],
               }
        g.node "update",
               "action:salesforce_record",
               name: "Append profile URL",
               configuration: {
                 "operation" => "update",
                 "object" => "Contact",
                 "record_id" => "={{ $trigger.id }}",
                 "fields" => {
                   "values" => [
                     {
                       "key" => "Description",
                       "value" =>
                         "={{ ($json.record.Description ? $json.record.Description + '\\n\\n' : '') + $helpers.absoluteUrl('/u/' + $trigger.user.username) }}",
                     },
                   ],
                 },
               }
        g.chain "trigger", "existing"
        g.connect "existing", "get", output: "true"
        g.chain "get", "missing_url"
        g.connect "missing_url", "update", output: "true"
      end
    Fabricate(:discourse_workflows_workflow, created_by: admin, published: true, **graph)
  end

  before { Salesforce.seed_groups! }

  def queued_jobs
    Jobs::DiscourseWorkflows::ExecuteWorkflow.jobs
  end

  def run_queued_workflow
    Jobs::DiscourseWorkflows::ExecuteWorkflow.new.execute(
      queued_jobs.first["args"].first.symbolize_keys,
    )
  end

  def stub_existing_contact(description)
    stub_salesforce_person_lookup("Contact", user.email, id: contact_id)
    stub_request(:get, contact_path).with(query: { fields: "Description" }).to_return(
      status: 200,
      body: { Id: contact_id, Description: description }.to_json,
    )
  end

  def description_update(value)
    a_request(:patch, contact_path).with(body: { Description: value }.to_json)
  end

  it "appends the profile URL to the description of an existing contact" do
    stub_existing_contact("Old notes")
    stub_request(:patch, contact_path).to_return(status: 204)

    Salesforce::Contact.create!(user)
    expect(queued_jobs.size).to eq(1)
    run_queued_workflow

    expect(DiscourseWorkflows::Execution.last.status).to eq("success")
    expect(description_update("Old notes\n\n#{profile_url}")).to have_been_made.once
  end

  it "sets just the profile URL when the description is blank" do
    stub_existing_contact(nil)
    stub_request(:patch, contact_path).to_return(status: 204)

    Salesforce::Contact.create!(user)
    expect(queued_jobs.size).to eq(1)
    run_queued_workflow

    expect(DiscourseWorkflows::Execution.last.status).to eq("success")
    expect(description_update(profile_url)).to have_been_made.once
  end

  it "does not append the profile URL twice" do
    stub_existing_contact("Old notes\n\n#{profile_url}")

    Salesforce::Contact.create!(user)
    expect(queued_jobs.size).to eq(1)
    run_queued_workflow

    expect(DiscourseWorkflows::Execution.last.status).to eq("success")
    expect(
      a_request(:get, contact_path).with(query: { fields: "Description" }),
    ).to have_been_made.once
    expect(a_request(:patch, contact_path)).not_to have_been_made
  end

  it "leaves a contact created by Discourse alone" do
    stub_salesforce_person_lookup("Contact", user.email)
    stub_request(:post, "#{api_path}/Contact").to_return(
      status: 200,
      body: { id: contact_id }.to_json,
    )

    Salesforce::Contact.create!(user)
    expect(queued_jobs.size).to eq(1)
    run_queued_workflow

    expect(DiscourseWorkflows::Execution.last.status).to eq("success")
    expect(a_request(:post, "#{api_path}/Contact")).to have_been_made.once
    expect(a_request(:get, /#{Regexp.escape(contact_path)}/)).not_to have_been_made
    expect(a_request(:patch, contact_path)).not_to have_been_made
  end

  it "leaves the contact alone when the user's email is not verified" do
    unverified_user = Fabricate(:user)
    stub_salesforce_person_lookup("Contact", unverified_user.email, id: contact_id)

    Salesforce::Contact.create!(unverified_user)
    expect(queued_jobs.size).to eq(1)
    run_queued_workflow

    expect(DiscourseWorkflows::Execution.last.status).to eq("success")
    expect(a_request(:get, /#{Regexp.escape(contact_path)}/)).not_to have_been_made
    expect(a_request(:patch, contact_path)).not_to have_been_made
  end
end
