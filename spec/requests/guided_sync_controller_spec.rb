# frozen_string_literal: true

RSpec.describe Salesforce::GuidedSyncController do
  fab!(:admin)
  fab!(:user)

  before { SiteSetting.salesforce_enabled = true }

  describe "#index" do
    it "renders the admin application when opening the demo directly" do
      sign_in(admin)

      get "/admin/plugins/discourse-salesforce/guided-sync"

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Discourse-Route"]).to eq("salesforce/guided_sync/index")
    end

    it "rejects non-admin users" do
      sign_in(user)

      get "/admin/plugins/discourse-salesforce/guided-sync"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "shared demo connection" do
    it "persists one connection for subsequent wizard visits" do
      sign_in(admin)
      put "/salesforce/admin/guided-sync/connection.json", params: { environment: "production" }
      expect(response).to have_http_status(:ok)
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response.parsed_body.fetch("connection")).to eq("environment" => "production")
      put "/salesforce/admin/guided-sync/connection.json", params: { environment: "invalid" }
      expect(response).to have_http_status(:bad_request)
      expect(PluginStore.get(Salesforce::PLUGIN_NAME, "guided_sync_connection")).to eq(
        "environment" => "production",
      )
    end

    it "rejects connection changes by non-admins" do
      sign_in(user)
      put "/salesforce/admin/guided-sync/connection.json", params: { environment: "sandbox" }
      expect(response).to have_http_status(:forbidden)
      expect(PluginStore.get(Salesforce::PLUGIN_NAME, "guided_sync_connection")).to be_nil
    end
  end

  describe "configuration generation" do
    let(:configuration) do
      {
        name: "Lead sync",
        object: "Lead",
        group: "community-members",
        schedule: "daily",
        onJoin: true,
        onChange: false,
        backfill: true,
        mappings: [{ id: 1, source: "first", destination: "FirstName", policy: "keep" }],
      }
    end

    before { SiteSetting.enable_discourse_workflows = true }

    it "saves independent Lead and Contact configurations with their own published workflows" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           }
      expect(response).to have_http_status(:created)
      lead = response.parsed_body.fetch("configuration")
      lead_ids = lead.fetch("workflows").map { |workflow| workflow.fetch("id") }
      expect(
        lead.fetch("workflows").map { |workflow| workflow.fetch("purpose") },
      ).to contain_exactly("join", "refresh", "backfill")
      drafts = DiscourseWorkflows::Workflow.where(id: lead_ids)
      expect(drafts.count).to eq(3)
      expect(drafts.pluck(:active_version_id)).to all(be_present)
      expect(drafts.map { |workflow| workflow.nodes.map { |node| node["type"] } }).to all(
        eq(%w[trigger:user_created action:http_request]),
      )

      contact_configuration =
        configuration.merge(
          name: "Contact sync",
          object: "Contact",
          group: "customers",
          schedule: "manual",
          backfill: false,
        )
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: contact_configuration,
           }
      expect(response).to have_http_status(:created)
      contact = response.parsed_body.fetch("configuration")
      expect(
        contact.fetch("workflows").map { |workflow| workflow.fetch("id") } & lead_ids,
      ).to be_empty
      expect(contact.fetch("workflows").map { |workflow| workflow.fetch("purpose") }).to eq(
        ["join"],
      )

      execution =
        Fabricate(
          :discourse_workflows_execution,
          workflow: DiscourseWorkflows::Workflow.find(lead_ids.first),
        )
      put "/salesforce/admin/guided-sync/configurations/#{lead.fetch("id")}.json",
          params: {
            configuration: configuration.merge(name: "Partner sync", group: "partners"),
          }
      expect(response).to have_http_status(:ok)
      expect(
        response
          .parsed_body
          .dig("configuration", "workflows")
          .map { |workflow| workflow.fetch("id") },
      ).to match_array(lead_ids)
      renamed = response.parsed_body.dig("configuration", "workflows")
      renamed.each do |workflow|
        expected_name = "Partner sync · Lead · #{workflow.fetch("purpose")}"
        expect(workflow.fetch("name")).to eq(expected_name)
        expect(DiscourseWorkflows::Workflow.find(workflow.fetch("id")).name).to eq(expected_name)
      end
      expect(execution.reload.workflow_id).to eq(lead_ids.first)
      contact
        .fetch("workflows")
        .each do |workflow|
          expect(DiscourseWorkflows::Workflow.find(workflow.fetch("id")).name).to eq(
            workflow.fetch("name"),
          )
        end

      get "/salesforce/admin/guided-sync/configurations.json"
      expect(
        response
          .parsed_body
          .fetch("configurations")
          .map { |record| record.slice("object", "group", "schedule") },
      ).to contain_exactly(
        { "object" => "Lead", "group" => "partners", "schedule" => "daily" },
        { "object" => "Contact", "group" => "customers", "schedule" => "manual" },
      )
    end

    it "persists category-based Cases and creates only the selected response workflows" do
      sign_in(admin)
      case_configuration = {
        name: "Support case sync",
        kind: "posts",
        object: "Case",
        category: "support",
        schedule: "manual",
        onCreate: true,
        onEdit: true,
        outboundReplies: true,
        inboundReplies: false,
        backfill: true,
        mappings: [
          { id: 1, source: "title", destination: "Subject", policy: "overwrite" },
          { id: 2, source: "version", destination: "Product_Version__c", policy: "overwrite" },
          { id: 3, source: "attachments", destination: "files", policy: "overwrite" },
        ],
      }
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: case_configuration,
           },
           as: :json
      expect(response).to have_http_status(:created)
      record = response.parsed_body.fetch("configuration")
      workflows = record.fetch("workflows")
      expect(workflows.map { |workflow| workflow.fetch("purpose") }).to contain_exactly(
        "case_create",
        "case_update",
        "topic_to_case",
        "backfill",
      )
      expect(
        DiscourseWorkflows::Workflow.where(
          id: workflows.map { |workflow| workflow.fetch("id") },
        ).pluck(:active_version_id),
      ).to all(be_present)

      put "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json",
          params: {
            configuration:
              case_configuration.merge(category: "enterprise-support", inboundReplies: true),
          },
          as: :json
      expect(response).to have_http_status(:ok)
      updated_workflows = response.parsed_body.dig("configuration", "workflows")
      expect(updated_workflows.map { |workflow| workflow.fetch("purpose") }).to contain_exactly(
        "case_create",
        "case_update",
        "topic_to_case",
        "case_to_topic",
        "backfill",
      )
      expect(
        updated_workflows.select { |workflow| workflow.fetch("purpose") != "case_to_topic" },
      ).to match_array(workflows)

      get "/salesforce/admin/guided-sync/configurations.json"
      saved = response.parsed_body.fetch("configurations").first
      expect(saved.slice("kind", "object", "category", "inboundReplies", "mappings")).to eq(
        "kind" => "posts",
        "object" => "Case",
        "category" => "enterprise-support",
        "inboundReplies" => true,
        "mappings" => record.fetch("mappings"),
      )
      put "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json",
          params: {
            configuration:
              case_configuration.merge(onEdit: false, outboundReplies: false, backfill: false),
          },
          as: :json
      expect(response).to have_http_status(:ok)
      remaining = response.parsed_body.dig("configuration", "workflows")
      expect(remaining.map { |workflow| workflow["purpose"] }).to eq(["case_create"])
      removed_ids =
        updated_workflows.map { |workflow| workflow["id"] } -
          remaining.map { |workflow| workflow["id"] }
      expect(DiscourseWorkflows::Workflow.where(id: removed_ids)).to be_empty
    end

    it "removes disabled workflows and recreates them only when re-enabled" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      record = response.parsed_body.fetch("configuration")
      original = record.fetch("workflows").index_by { |workflow| workflow.fetch("purpose") }
      backfill_id = original.fetch("backfill").fetch("id")
      Fabricate(
        :discourse_workflows_execution,
        workflow: DiscourseWorkflows::Workflow.find(backfill_id),
      )
      put "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json",
          params: {
            configuration: configuration.merge(backfill: false, schedule: "manual"),
          },
          as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("configuration", "workflows")).to eq([original.fetch("join")])
      expect(DiscourseWorkflows::Workflow.exists?(backfill_id)).to eq(false)
      expect(DiscourseWorkflows::Workflow.exists?(original.fetch("refresh").fetch("id"))).to eq(
        false,
      )
      expect(DiscourseWorkflows::Execution.exists?(workflow_id: backfill_id)).to eq(false)
      put "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json",
          params: {
            configuration: configuration,
          },
          as: :json
      expect(response).to have_http_status(:ok)
      updated =
        response
          .parsed_body
          .dig("configuration", "workflows")
          .index_by { |workflow| workflow.fetch("purpose") }
      expect(updated.fetch("join")).to eq(original.fetch("join"))
      expect(updated.fetch("backfill").fetch("id")).not_to eq(backfill_id)
    end

    it "rolls back configuration changes if a disabled workflow is used elsewhere" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      record = response.parsed_body.fetch("configuration")
      backfill_id =
        record.fetch("workflows").find { |workflow| workflow["purpose"] == "backfill" }.fetch("id")
      graph =
        build_workflow_graph do |workflow_graph|
          workflow_graph.node "trigger-1", "trigger:manual"
          workflow_graph.node "call-1",
                              "action:workflow_call",
                              configuration: {
                                "workflow_id" => backfill_id,
                              }
        end
      Fabricate(:discourse_workflows_workflow, created_by: admin, published: true, **graph)
      put "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json",
          params: {
            configuration: configuration.merge(backfill: false, group: "partners"),
          },
          as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Salesforce::GuidedSyncConfiguration.all).to eq([record])
      expect(DiscourseWorkflows::Workflow.exists?(backfill_id)).to eq(true)
    end

    it "protects managed workflow definitions while allowing execution inspection and editable duplication" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      record = response.parsed_body.fetch("configuration")
      workflow_id = record.fetch("workflows").first.fetch("id")
      workflow = DiscourseWorkflows::Workflow.find(workflow_id)
      expect(workflow.published?).to eq(true)

      get "/admin/plugins/discourse-workflows/workflows/#{workflow_id}.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("workflow", "managed_by", "name")).to eq("Salesforce")
      expect(response.parsed_body.dig("workflow", "managed_by", "url")).to eq(
        "/admin/plugins/discourse-salesforce/guided-sync?configuration=#{record.fetch("id")}",
      )
      get "/admin/plugins/discourse-workflows/workflows/#{workflow_id}/executions.json"
      expect(response).to have_http_status(:ok)

      put "/admin/plugins/discourse-workflows/workflows/#{workflow_id}.json",
          params: {
            workflow: {
              name: "Changed directly",
            },
          },
          as: :json
      expect(response).to have_http_status(:forbidden)
      put "/admin/plugins/discourse-workflows/workflows/#{workflow_id}.json",
          params: {
            workflow: {
              published: false,
            },
          },
          as: :json
      expect(response).to have_http_status(:forbidden)
      delete "/admin/plugins/discourse-workflows/workflows/#{workflow_id}.json"
      expect(response).to have_http_status(:forbidden)
      post "/admin/plugins/discourse-workflows/workflows/#{workflow_id}/versions/#{workflow.version_id}/restore.json"
      expect(response).to have_http_status(:forbidden)
      post "/admin/plugins/discourse-workflows/workflows/#{workflow_id}/variables.json",
           params: {
             key: "example",
           }
      expect(response).to have_http_status(:forbidden)

      post "/admin/plugins/discourse-workflows/workflows/#{workflow_id}/duplicate.json"
      expect(response).to have_http_status(:created)
      copy = response.parsed_body.fetch("workflow")
      expect(copy.fetch("managed_by")).to be_nil
      expect(copy.fetch("nodes")).to eq(workflow.nodes)
      expect(copy.fetch("connections")).to eq(workflow.connections)
      expect(copy.fetch("active_version_id")).to be_nil
      put "/admin/plugins/discourse-workflows/workflows/#{copy.fetch("id")}.json",
          params: {
            workflow: {
              name: "My independent copy",
            },
          },
          as: :json
      expect(response).to have_http_status(:ok)
      expect(workflow.reload.name).to eq(record.fetch("workflows").first.fetch("name"))
    end

    it "requires Workflows to be enabled before saving" do
      sign_in(admin)
      SiteSetting.enable_discourse_workflows = false

      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           }

      expect(response).to have_http_status(:forbidden)
      expect(Salesforce::GuidedSyncConfiguration.all).to be_empty
    end

    it "rejects non-admin configuration access and generation" do
      sign_in(user)
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response).to have_http_status(:forbidden)

      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "#destroy_configuration" do
    let(:configuration) do
      {
        name: "Lead sync",
        object: "Lead",
        group: "community-members",
        schedule: "daily",
        onJoin: true,
        onChange: false,
        backfill: true,
        mappings: [{ id: 1, source: "first", destination: "FirstName", policy: "keep" }],
      }
    end

    before { SiteSetting.enable_discourse_workflows = true }

    it "deletes only the chosen configuration and its remaining workflows" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      lead = response.parsed_body.fetch("configuration")
      workflow_ids = lead.fetch("workflows").map { |workflow| workflow.fetch("id") }
      DiscourseWorkflows::Workflow.find(workflow_ids.first).destroy!
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration.merge(name: "Contact sync", object: "Contact"),
           },
           as: :json
      contact = response.parsed_body.fetch("configuration")
      contact_workflow_ids = contact.fetch("workflows").map { |workflow| workflow.fetch("id") }

      delete "/salesforce/admin/guided-sync/configurations/#{lead.fetch("id")}.json"

      expect(response).to have_http_status(:no_content)
      expect(DiscourseWorkflows::Workflow.where(id: workflow_ids)).to be_empty
      expect(
        DiscourseWorkflows::Workflow.where(id: contact_workflow_ids).pluck(:id),
      ).to match_array(contact_workflow_ids)
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response.parsed_body.fetch("configurations")).to eq([contact])

      delete "/salesforce/admin/guided-sync/configurations/#{lead.fetch("id")}.json"
      expect(response).to have_http_status(:not_found)
    end

    it "keeps the whole configuration when a related workflow is called elsewhere" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      record = response.parsed_body.fetch("configuration")
      workflow_ids = record.fetch("workflows").map { |workflow| workflow.fetch("id") }
      graph =
        build_workflow_graph do |workflow_graph|
          workflow_graph.node "trigger-1", "trigger:manual"
          workflow_graph.node "call-1",
                              "action:workflow_call",
                              configuration: {
                                "workflow_id" => workflow_ids.last,
                              }
        end
      Fabricate(:discourse_workflows_workflow, created_by: admin, published: true, **graph)

      delete "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors")).to eq(
        [I18n.t("salesforce.guided_sync.delete_failed")],
      )
      expect(DiscourseWorkflows::Workflow.where(id: workflow_ids).pluck(:id)).to match_array(
        workflow_ids,
      )
      get "/salesforce/admin/guided-sync/configurations.json"
      expect(response.parsed_body.fetch("configurations")).to eq([record])
    end

    it "rejects non-admin deletion" do
      sign_in(admin)
      post "/salesforce/admin/guided-sync/configurations.json",
           params: {
             configuration: configuration,
           },
           as: :json
      record = response.parsed_body.fetch("configuration")
      sign_in(user)

      delete "/salesforce/admin/guided-sync/configurations/#{record.fetch("id")}.json"

      expect(response).to have_http_status(:forbidden)
      expect(Salesforce::GuidedSyncConfiguration.all).to eq([record])
    end
  end
end
