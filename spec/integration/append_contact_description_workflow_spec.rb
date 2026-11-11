# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Salesforce contact description workflow example", discourse_workflows: true do
  include_context "with salesforce spec helper"

  fab!(:admin)
  fab!(:user) { Fabricate(:verified_user, username: "alex_morgan") }

  let(:contact_id) { "003000000000001AAA" }
  let(:contact_path) { "#{api_path}/Contact/#{contact_id}" }
  let(:profile_url) { "#{Discourse.base_url}/u/alex_morgan" }

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
               name: "Was already in Salesforce",
               configuration: {
                 "combinator" => "and",
                 "conditions" => [
                   {
                     "id" => "1",
                     "leftValue" => "={{ $json.created }}",
                     "operator" => {
                       "type" => "boolean",
                       "operation" => "false",
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
                 "record_id" => "={{ $json.id }}",
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
                     "rightValue" =>
                       "={{ $helpers.absoluteUrl('/u/' + $('Contact linked').first().json.user.username) }}",
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
                 "record_id" => "={{ $json.id }}",
                 "fields" => {
                   "values" => [
                     {
                       "key" => "Description",
                       "value" =>
                         "={{ ($json.record.Description ? $json.record.Description + '\\n\\n' : '') + $helpers.absoluteUrl('/u/' + $('Contact linked').first().json.user.username) }}",
                     },
                   ],
                 },
               }
        g.chain "trigger", "existing"
        g.connect "existing", "get", output: "true"
        g.chain "get", "missing_url"
        g.connect "missing_url", "update", output: "true"
      end
    workflow = Fabricate(:discourse_workflows_workflow, created_by: admin, published: true, **graph)
    publish_workflow!(workflow)
    workflow
  end

  before { Salesforce.seed_groups! }

  def link_contact
    Salesforce::Contact.create!(user)

    jobs = Jobs::DiscourseWorkflows::ExecuteWorkflow.jobs
    expect(jobs.size).to eq(1)
    trigger_data = jobs.first["args"].first["trigger_data"]
    DiscourseWorkflows::Executor.new(workflow, "trigger", trigger_data).run
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

    execution = link_contact

    expect(execution.status).to eq("success")
    expect(description_update("Old notes\n\n#{profile_url}")).to have_been_made.once
  end

  it "sets just the profile URL when the description is blank" do
    stub_existing_contact(nil)
    stub_request(:patch, contact_path).to_return(status: 204)

    execution = link_contact

    expect(execution.status).to eq("success")
    expect(description_update(profile_url)).to have_been_made.once
  end

  it "does not append the profile URL twice" do
    stub_existing_contact("Old notes\n\n#{profile_url}")

    execution = link_contact

    expect(execution.status).to eq("success")
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

    execution = link_contact

    expect(execution.status).to eq("success")
    expect(a_request(:post, "#{api_path}/Contact")).to have_been_made.once
    expect(a_request(:get, /#{Regexp.escape(contact_path)}/)).not_to have_been_made
    expect(a_request(:patch, contact_path)).not_to have_been_made
  end
end
