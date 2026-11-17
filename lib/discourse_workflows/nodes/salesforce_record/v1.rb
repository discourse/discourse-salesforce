# frozen_string_literal: true

if defined?(DiscourseWorkflows)
  module DiscourseWorkflows
    module Nodes
      module SalesforceRecord
        class V1 < DiscourseWorkflows::NodeType
          OPERATIONS = %w[get update].freeze

          RECORD_PROPERTIES = {
            "object" => {
              "type" => "string",
              "description" => "Salesforce object API name",
            },
            "id" => {
              "type" => "string",
              "description" => "Salesforce record ID",
            },
          }.freeze

          GET_OUTPUT_SCHEMA =
            DiscourseWorkflows::Schema.document(
              RECORD_PROPERTIES.merge(
                "record" => {
                  "type" => "object",
                  "description" => "Fields returned by Salesforce",
                },
              ),
            )

          UPDATE_OUTPUT_SCHEMA =
            DiscourseWorkflows::Schema.document(
              RECORD_PROPERTIES.merge(
                "fields" => {
                  "type" => "object",
                  "description" => "Fields sent to Salesforce",
                },
              ),
            )

          description(
            name: "action:salesforce_record",
            version: "1.0",
            defaults: {
              icon: "fab-salesforce",
              color: "blue",
            },
            available: -> { SiteSetting.salesforce_enabled },
            unavailable_reason_key: "discourse_workflows.node_unavailable.requires_salesforce",
            output_contracts: [
              {
                variants: [
                  { schema: GET_OUTPUT_SCHEMA, display_options: { show: { operation: ["get"] } } },
                  {
                    schema: UPDATE_OUTPUT_SCHEMA,
                    display_options: {
                      show: {
                        operation: ["update"],
                      },
                    },
                  },
                ],
              },
            ],
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

            case operation
            when "get"
              names =
                exec_ctx
                  .get_node_parameter("field_names", item_index)
                  .to_s
                  .split(",")
                  .map(&:strip)
                  .compact_blank
              exec_ctx.ensure_no_expression_errors!
              check!(object, ::Salesforce::Person::FIELD_NAME_PATTERN, "invalid_object", item_index)
              check!(
                record_id,
                ::Salesforce::Associations::ID_PATTERN,
                "invalid_record_id",
                item_index,
              )
              names.each do |name|
                check!(name, ::Salesforce::Person::FIELD_NAME_PATTERN, "invalid_field", item_index)
              end
              fetch(object, record_id, names)
            when "update"
              pairs = exec_ctx.get_node_parameter("fields.values", item_index, default: [])
              exec_ctx.ensure_no_expression_errors!
              check!(object, ::Salesforce::Person::FIELD_NAME_PATTERN, "invalid_object", item_index)
              check!(
                record_id,
                ::Salesforce::Associations::ID_PATTERN,
                "invalid_record_id",
                item_index,
              )
              update(object, record_id, update_fields(pairs, item_index))
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

          def update(object, record_id, fields)
            api.patch("sobjects/#{object}/#{record_id}", fields)

            { object: object, id: record_id, fields: fields }
          end

          def api
            @api ||= ::Salesforce::Api.new
          end

          def update_fields(pairs, item_index)
            fields =
              Array
                .wrap(pairs)
                .to_h do |pair|
                  name = pair["key"].to_s.strip
                  check!(
                    name,
                    ::Salesforce::Person::FIELD_NAME_PATTERN,
                    "invalid_field",
                    item_index,
                  )
                  if pair["value"].nil?
                    raise_node_error!(
                      I18n.t("salesforce.discourse_workflows.record.missing_value", field: name),
                      item_index: item_index,
                    )
                  end
                  [name, pair["value"]]
                end
            return fields if fields.present?

            raise_node_error!(
              I18n.t("salesforce.discourse_workflows.record.no_fields"),
              item_index: item_index,
            )
          end

          def check!(value, pattern, error_key, item_index)
            return if pattern.match?(value)

            raise_node_error!(
              I18n.t("salesforce.discourse_workflows.record.#{error_key}", value: value),
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
