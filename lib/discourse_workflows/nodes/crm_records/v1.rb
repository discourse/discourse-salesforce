# frozen_string_literal: true

if defined?(DiscourseWorkflows)
  module DiscourseWorkflows
    module Nodes
      module CrmRecords
        class V1 < DiscourseWorkflows::NodeType
          INBOUND_FLOWS =
            DiscourseCrm::SyncConfiguration::PROVIDERS
              .filter_map do |key, definition|
                flow = definition.flow("inbound", "users")
                [key, flow] if flow
              end
              .to_h
              .freeze
          PROVIDERS = INBOUND_FLOWS.keys.freeze
          OBJECTS = INBOUND_FLOWS.values.flat_map(&:objects).uniq.freeze

          OUTPUT_SCHEMA =
            DiscourseWorkflows::Schema.document(
              "provider" => {
                "type" => "string",
                "description" => "CRM provider the record was pulled from",
              },
              "object" => {
                "type" => "string",
                "description" => "CRM object the record belongs to",
              },
              "user" => {
                "type" => "object",
                "description" => "Discourse user the records are linked to",
                "properties" => DiscourseWorkflows::Schema::USER_PROPERTIES,
              },
              "records" => {
                "type" => "array",
                "description" => "Every record linked to the user, newest first",
                "items" => {
                  "type" => "object",
                  "properties" => {
                    "external_id" => {
                      "type" => "string",
                      "description" => "ID of the record in the CRM",
                    },
                    "record" => {
                      "type" => "object",
                      "description" => "Properties kept by the pull configuration",
                    },
                    "company" => {
                      "type" => %w[object null],
                      "description" => "Properties of the record's primary company, when pulled",
                    },
                  },
                },
              },
            )

          description(
            name: "action:crm_records",
            version: "1.0",
            defaults: {
              icon: "address-card",
              color: "blue",
            },
            available: -> { DiscourseCrm::SyncConfiguration.active.user_pulls.exists? },
            unavailable_reason_key: "discourse_workflows.node_unavailable.requires_crm_pull",
            output_contracts: [{ schema: OUTPUT_SCHEMA }],
            capabilities: {
              run_scope: "all_items",
            },
            properties: {
              provider: {
                type: :options,
                required: true,
                options: PROVIDERS,
                default: PROVIDERS.first,
                no_data_expression: true,
              },
              object: {
                type: :options,
                required: true,
                options: OBJECTS,
                default: OBJECTS.first,
                no_data_expression: true,
              },
            },
          )

          def execute(exec_ctx)
            provider = exec_ctx.get_node_parameter("provider", 0).to_s
            object = exec_ctx.get_node_parameter("object", 0).to_s
            exec_ctx.ensure_no_expression_errors!
            flow = INBOUND_FLOWS[provider]
            if flow.nil?
              raise_node_error!(
                I18n.t("salesforce.discourse_workflows.records.unknown_provider", value: provider),
              )
            end
            if flow.objects.exclude?(object)
              raise_node_error!(
                I18n.t("salesforce.discourse_workflows.records.unknown_object", value: object),
              )
            end
            [list(provider, object).map { |data| wrap(data) }]
          end

          private

          def list(provider, object)
            account = DiscourseCrm::SyncConfiguration.provider_definition(provider).account
            links =
              DiscourseCrm::RecordLink
                .within(provider: provider, account: account, object: object, direction: "inbound")
                .joins(:record)
                .includes(record: :company)
                .order(
                  "crm_record_links.user_id ASC, crm_records.updated_at DESC, crm_records.external_id ASC",
                )
                .group_by(&:user_id)
            users = ::User.where(id: links.keys).index_by(&:id)
            links.filter_map do |user_id, user_links|
              user = users[user_id]
              next unless user
              {
                provider: provider,
                object: object,
                user: serialize_user(user),
                records:
                  user_links.map do |link|
                    {
                      external_id: link.external_id,
                      record: link.record.data,
                      company: link.record.company&.data,
                    }
                  end,
              }
            end
          end
        end
      end
    end
  end
end
