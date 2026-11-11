# frozen_string_literal: true

if defined?(DiscourseWorkflows)
  module DiscourseWorkflows
    module Nodes
      module SalesforcePersonLinked
        class V1 < DiscourseWorkflows::NodeType
          OBJECTS = %w[Contact Lead].freeze

          OUTPUT_SCHEMA =
            DiscourseWorkflows::Schema.merge(
              DiscourseWorkflows::Schema.document(
                "object" => {
                  "type" => "string",
                  "enum" => OBJECTS,
                },
                "id" => {
                  "type" => "string",
                  "description" => "Salesforce record ID",
                },
                "created" => {
                  "type" => "boolean",
                  "description" =>
                    "True when the record was created in Salesforce, false when an existing one was linked",
                },
              ),
              DiscourseWorkflows::Schema::USER_SCHEMA,
              DiscourseWorkflows::Schema::ACTOR_SCHEMA,
            ).freeze

          description(
            name: "trigger:salesforce_person_linked",
            version: "1.0",
            defaults: {
              icon: "fab-salesforce",
              color: "blue",
            },
            group: "discourse_triggers",
            event: :salesforce_person_linked,
            available: -> { SiteSetting.salesforce_enabled },
            unavailable_reason_key: "discourse_workflows.node_unavailable.requires_salesforce",
            output_contracts: [{ schema: OUTPUT_SCHEMA }],
            properties: {
              objects: {
                type: :multi_options,
                required: false,
                default: [],
                options: OBJECTS,
              },
            },
          )

          def self.from_event(event_name, *args)
            new(event_name, *args)
          end

          def initialize(_event_name, user, object_name, record_id, payload = {})
            super(parameters: {})
            @user = user
            @object_name = object_name
            @record_id = record_id
            @created = payload[:created] == true
            @actor = payload[:acting_user]
          end

          def valid?
            @user.present? && OBJECTS.include?(@object_name) && @record_id.present?
          end

          def output
            {
              object: @object_name,
              id: @record_id,
              created: @created,
              user: serialize_user(@user),
              actor: serialize_user(@actor),
            }
          end

          def matches?(trigger_ctx)
            objects = Array.wrap(trigger_ctx.get_node_parameter("objects", [])).compact_blank
            objects.empty? || objects.map(&:to_s).include?(@object_name)
          end
        end
      end
    end
  end
end
