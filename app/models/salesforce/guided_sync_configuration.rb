# frozen_string_literal: true

module Salesforce
  class GuidedSyncConfiguration
    class DeletionError < StandardError
    end

    STORE_KEY = "guided_sync_configurations"

    def self.all
      PluginStore.get(PLUGIN_NAME, STORE_KEY) || []
    end

    def self.destroy!(id:, guardian:)
      unless defined?(DiscourseWorkflows::Workflow::Destroy) && guardian.can_manage_workflows?
        raise Discourse::InvalidAccess
      end

      DistributedMutex.synchronize("salesforce_guided_sync_configurations") do
        PluginStoreRow.transaction do
          records = all
          record = records.find { |configuration| configuration["id"] == id }
          raise Discourse::NotFound unless record
          workflow_ids = record.fetch("workflows", []).map { |workflow| workflow["id"] }
          DiscourseWorkflows::Workflow
            .where(id: workflow_ids)
            .order(:id)
            .each do |workflow|
              result =
                DiscourseWorkflows::Workflow::Destroy.call(
                  guardian: guardian,
                  params: {
                    workflow_id: workflow.id,
                  },
                )
              raise DeletionError, I18n.t("salesforce.guided_sync.delete_failed") if result.failure?
            end
          PluginStore.set(
            PLUGIN_NAME,
            STORE_KEY,
            records.reject { |configuration| configuration["id"] == id },
          )
        end
      end
    end

    def self.save!(configuration, id:, guardian:)
      unless defined?(DiscourseWorkflows::Workflow::Create) &&
               SiteSetting.enable_discourse_workflows && guardian.can_manage_workflows?
        raise Discourse::InvalidAccess
      end
      configuration = configuration.deep_stringify_keys
      configuration["kind"] ||= "users"
      posts = configuration["kind"] == "posts"
      valid_scope = posts ? configuration["category"].present? : configuration["group"].present?
      valid_object =
        (
          if posts
            configuration["object"] == "Case"
          else
            %w[Lead Contact DiscourseContact__c].include?(configuration["object"])
          end
        )
      unless configuration["name"].present? && configuration["name"].length <= 60 &&
               %w[users posts].include?(configuration["kind"]) && valid_object &&
               %w[daily hourly weekly manual].include?(configuration["schedule"]) && valid_scope &&
               configuration["mappings"].is_a?(Array) && configuration["mappings"].size <= 50
        raise Discourse::InvalidParameters.new(:configuration)
      end

      %w[onJoin onChange backfill onCreate onEdit outboundReplies inboundReplies].each do |key|
        configuration[key] = ActiveModel::Type::Boolean.new.cast(configuration[key])
      end

      DistributedMutex.synchronize("salesforce_guided_sync_configurations") do
        PluginStoreRow.transaction do
          records = all
          previous = id ? records.find { |record| record["id"] == id } : nil
          raise Discourse::NotFound if id && !previous
          if previous && previous["object"] != configuration["object"]
            raise Discourse::InvalidParameters.new(:object)
          end
          record_id = previous&.dig("id") || SecureRandom.uuid
          workflows = previous&.dig("workflows") || []
          purposes = []
          if posts
            purposes << "case_create" if configuration["onCreate"]
            purposes << "case_update" if configuration["onEdit"]
            purposes << "topic_to_case" if configuration["outboundReplies"]
            purposes << "case_to_topic" if configuration["inboundReplies"]
          else
            purposes << "join" if configuration["onJoin"]
            purposes << "change" if configuration["onChange"]
            purposes << "refresh" if configuration["schedule"] != "manual"
          end
          purposes << "backfill" if configuration["backfill"]
          generated =
            purposes.map do |purpose|
              existing = workflows.find { |workflow| workflow["purpose"] == purpose }
              name = "#{configuration["name"]} · #{configuration["object"]} · #{purpose}"
              graph = graph_for(configuration, purpose).merge(name: name)
              result =
                if existing && DiscourseWorkflows::Workflow.exists?(id: existing["id"])
                  DiscourseWorkflows::Workflow::Update.call(
                    guardian: guardian,
                    params: graph.merge(workflow_id: existing["id"]),
                  )
                else
                  DiscourseWorkflows::Workflow::Create.call(guardian: guardian, params: graph)
                end
              raise Discourse::InvalidParameters.new(:workflow) if result.failure?
              published =
                DiscourseWorkflows::Workflow::Publish.call(
                  guardian: guardian,
                  params: {
                    workflow_id: result.workflow.id,
                  },
                )
              raise Discourse::InvalidParameters.new(:workflow) if published.failure?
              {
                "id" => result.workflow.id,
                "name" => result.workflow.name,
                "purpose" => purpose,
                "status" => "published",
              }
            end
          workflows
            .reject { |workflow| purposes.include?(workflow["purpose"]) }
            .each do |workflow|
              next unless DiscourseWorkflows::Workflow.exists?(id: workflow["id"])
              result =
                DiscourseWorkflows::Workflow::Destroy.call(
                  guardian: guardian,
                  params: {
                    workflow_id: workflow["id"],
                  },
                )
              raise DeletionError, I18n.t("salesforce.guided_sync.delete_failed") if result.failure?
            end
          record = configuration.merge("id" => record_id, "workflows" => generated)
          records = records.reject { |entry| entry["id"] == record_id } + [record]
          PluginStore.set(PLUGIN_NAME, STORE_KEY, records)
          record
        end
      end
    end

    def self.graph_for(configuration, purpose)
      posts = configuration["kind"] == "posts"
      trigger_name = posts ? "Post created" : "User created"
      request_name = "HTTP request"
      {
        nodes: [
          {
            id: "trigger",
            name: trigger_name,
            type: posts ? "trigger:post_created" : "trigger:user_created",
            typeVersion: "1.0",
            parameters: {
            },
            credentials: {
            },
            position: {
              x: 0,
              y: 0,
            },
          },
          {
            id: "http-request",
            name: request_name,
            type: "action:http_request",
            typeVersion: "1.0",
            parameters: {
              method: "POST",
              url: "https://example.invalid/salesforce-demo",
              authentication: "none",
              dry_run: true,
              content_type: "json",
              body_json: {
                object: configuration["object"],
                scope: configuration["category"] || configuration["group"],
                operation: purpose,
                mappings: configuration["mappings"],
              }.to_json,
            },
            credentials: {
            },
            position: {
              x: 320,
              y: 0,
            },
          },
        ],
        connections: {
          trigger_name => {
            "main" => [[{ "node" => request_name, "type" => "main", "index" => 0 }]],
          },
        },
      }
    end
    private_class_method :graph_for
  end
end
