# frozen_string_literal: true

if defined?(DiscourseWorkflows)
  module DiscourseWorkflows
    module Nodes
      module SalesforceRecord
        class V1 < DiscourseWorkflows::NodeType
          OPERATIONS = %w[get update].freeze
          NAME_PATTERN = /\A[A-Za-z][A-Za-z0-9_]*\z/
          RECORD_ID_PATTERN = /\A[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?\z/

          OUTPUT_SCHEMA =
            DiscourseWorkflows::Schema.document(
              "object" => {
                "type" => "string",
                "description" => "Salesforce object API name",
              },
              "id" => {
                "type" => "string",
                "description" => "Salesforce record ID",
              },
              "record" => {
                "type" => "object",
                "description" => "Fields returned by Salesforce",
                "x-optional" => true,
              },
              "fields" => {
                "type" => "object",
                "description" => "Fields sent to Salesforce",
                "x-optional" => true,
              },
            ).freeze

          description(
            name: "action:salesforce_record",
            version: "1.0",
            defaults: {
              icon: "fab-salesforce",
              color: "blue",
            },
            available: -> { SiteSetting.salesforce_enabled },
            unavailable_reason_key: "discourse_workflows.node_unavailable.requires_salesforce",
            output_contracts: [{ schema: OUTPUT_SCHEMA }],
            capabilities: {
              run_scope: "per_item",
            },
            properties: {
              operation: {
                type: :options,
                required: true,
                options: OPERATIONS,
                default: "get",
                no_data_expression: true,
              },
              object: {
                type: :string,
                required: true,
              },
              record_id: {
                type: :string,
                required: true,
              },
              field_names: {
                type: :string,
                required: false,
                display_options: {
                  show: {
                    operation: ["get"],
                  },
                },
              },
              fields: {
                type: :fixed_collection,
                required: false,
                display_options: {
                  show: {
                    operation: ["update"],
                  },
                },
                type_options: {
                  multiple_values: true,
                },
                options: [
                  {
                    name: "values",
                    values: {
                      key: {
                        type: :string,
                        required: true,
                      },
                      value: {
                        type: :string,
                        required: true,
                      },
                    },
                  },
                ],
              },
              apply_assignment_rules: {
                type: :boolean,
                required: false,
                default: true,
                display_options: {
                  show: {
                    operation: ["update"],
                  },
                },
              },
            },
          )

          def execute(exec_ctx)
            items =
              exec_ctx.input_items.map.with_index do |item, item_index|
                result = process(exec_ctx, item_index)
                wrap(result, paired_item: exec_ctx.paired_item_for(item))
              end
            [items]
          end

          private

          def process(exec_ctx, item_index)
            operation = exec_ctx.get_node_parameter("operation", item_index, default: "get").to_s
            object = exec_ctx.get_node_parameter("object", item_index).to_s.strip
            record_id = exec_ctx.get_node_parameter("record_id", item_index).to_s.strip
            validate_object!(object, item_index)
            validate_record_id!(record_id, item_index)

            case operation
            when "get"
              names =
                field_names(exec_ctx.get_node_parameter("field_names", item_index), item_index)
              fetch(object, record_id, names)
            when "update"
              fields =
                update_fields(
                  exec_ctx.get_node_parameter("fields.values", item_index, default: []),
                  item_index,
                )
              exec_ctx.ensure_no_expression_errors!
              validate_update_fields!(fields, item_index)
              apply_rules =
                exec_ctx.get_node_parameter("apply_assignment_rules", item_index, default: true)
              update(object, record_id, fields, apply_rules != false)
            else
              raise_node_error!(
                I18n.t("discourse_workflows.errors.unknown_operation", operation: operation),
                item_index: item_index,
              )
            end
          rescue ::Salesforce::InvalidApiResponse => e
            raise_node_error!(
              salesforce_message(e).presence || I18n.t("salesforce.error.invalid_response"),
              item_index: item_index,
            )
          rescue ::Salesforce::InvalidCredentials
            raise_node_error!(
              I18n.t("salesforce.error.invalid_client_credentials"),
              item_index: item_index,
            )
          rescue Faraday::Error => e
            raise_node_error!(
              I18n.t("salesforce.discourse_workflows.record.request_failed", message: e.message),
              item_index: item_index,
            )
          end

          def fetch(object, record_id, names)
            path = "sobjects/#{object}/#{record_id}"
            path += "?fields=#{names.join(",")}" if names.present?
            record = api.get(path)

            { object: object, id: record_id, record: record.except("attributes") }
          end

          def update(object, record_id, fields, apply_assignment_rules)
            headers = apply_assignment_rules ? {} : { "Sforce-Auto-Assign" => "FALSE" }
            api.patch("sobjects/#{object}/#{record_id}", fields, headers: headers)

            { object: object, id: record_id, fields: fields }
          end

          def api
            @api ||= ::Salesforce::Api.new
          end

          def field_names(value, item_index)
            names = value.to_s.split(",").map(&:strip).compact_blank
            names.each { |name| validate_field_name!(name, item_index) }
            names
          end

          def update_fields(pairs, item_index)
            Array
              .wrap(pairs)
              .each_with_object({}) do |pair, fields|
                name = pair["key"].to_s.strip
                validate_field_name!(name, item_index)
                fields[name] = pair["value"]
              end
          end

          def validate_update_fields!(fields, item_index)
            if fields.empty?
              raise_node_error!(
                I18n.t("salesforce.discourse_workflows.record.no_fields"),
                item_index: item_index,
              )
            end

            fields.each do |name, value|
              next if !value.nil?

              raise_node_error!(
                I18n.t("salesforce.discourse_workflows.record.missing_value", field: name),
                item_index: item_index,
              )
            end
          end

          def validate_object!(object, item_index)
            return if NAME_PATTERN.match?(object)

            raise_node_error!(
              I18n.t("salesforce.discourse_workflows.record.invalid_object", name: object),
              item_index: item_index,
            )
          end

          def validate_field_name!(name, item_index)
            return if NAME_PATTERN.match?(name)

            raise_node_error!(
              I18n.t("salesforce.discourse_workflows.record.invalid_field", field: name),
              item_index: item_index,
            )
          end

          def validate_record_id!(record_id, item_index)
            return if RECORD_ID_PATTERN.match?(record_id)

            raise_node_error!(
              I18n.t("salesforce.discourse_workflows.record.invalid_record_id", id: record_id),
              item_index: item_index,
            )
          end

          def salesforce_message(error)
            messages =
              Array
                .wrap(JSON.parse(error.message))
                .filter_map { |entry| entry["message"] if entry.is_a?(Hash) }
            messages.presence&.join("; ") || error.message
          rescue JSON::ParserError
            error.message
          end
        end
      end
    end
  end
end
