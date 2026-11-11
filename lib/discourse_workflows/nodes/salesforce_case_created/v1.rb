# frozen_string_literal: true

if defined?(DiscourseWorkflows)
  module DiscourseWorkflows
    module Nodes
      module SalesforceCaseCreated
        class V1 < DiscourseWorkflows::NodeType
          OUTPUT_SCHEMA =
            DiscourseWorkflows::Schema.merge(
              DiscourseWorkflows::Schema.document(
                "case" => {
                  "type" => "object",
                  "description" => "The Salesforce Case created for the topic",
                  "properties" => {
                    "id" => {
                      "type" => "string",
                      "description" => "Salesforce Case record ID",
                    },
                    "number" => {
                      "type" => %w[string null],
                    },
                    "status" => {
                      "type" => %w[string null],
                    },
                  },
                },
              ),
              DiscourseWorkflows::Schema::TOPIC_LIST_ITEM_SCHEMA,
              DiscourseWorkflows::Schema::TOPIC_AUTHOR_SCHEMA,
              DiscourseWorkflows::Schema::ACTOR_SCHEMA,
            ).freeze

          description(
            name: "trigger:salesforce_case_created",
            version: "1.0",
            defaults: {
              icon: "fab-salesforce",
              color: "blue",
            },
            group: "discourse_triggers",
            event: :salesforce_case_created,
            available: -> { SiteSetting.salesforce_enabled },
            unavailable_reason_key: "discourse_workflows.node_unavailable.requires_salesforce",
            output_contracts: [{ schema: OUTPUT_SCHEMA }],
            properties: {
              **CATEGORY_FILTER_PROPERTIES,
              **TAG_FILTER_PROPERTIES,
            },
          )

          def initialize(salesforce_case, payload = {})
            super(parameters: {})
            @salesforce_case = salesforce_case
            @actor = payload[:acting_user]
          end

          def valid?
            @salesforce_case.present? && topic.present?
          end

          def output
            {
              case: {
                id: @salesforce_case.uid,
                number: @salesforce_case.number,
                status: @salesforce_case.status,
              },
              topic: serialize_topic_list_item(topic),
              user: serialize_user(topic.user),
              actor: serialize_user(@actor),
            }
          end

          def matches?(trigger_ctx)
            matches_topic_filters?(topic, trigger_ctx)
          end

          private

          def topic
            @topic ||= @salesforce_case.topic
          end
        end
      end
    end
  end
end
