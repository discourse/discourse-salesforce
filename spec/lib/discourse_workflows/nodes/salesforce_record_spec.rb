# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe DiscourseWorkflows::Nodes::SalesforceRecord::V1, discourse_workflows: true do
  include_context "with salesforce spec helper"

  let(:record_id) { "500000000000001AAA" }

  def run(configuration)
    configuration = configuration.deep_stringify_keys
    output = execute_node(configuration: configuration)
    expect(output).to match_node_output_schema(described_class, configuration: configuration)
    output
  end

  def update_config(values)
    {
      "operation" => "update",
      "object" => "Case",
      "record_id" => record_id,
      "fields" => {
        "values" => values,
      },
    }
  end

  def expect_node_error(configuration, message)
    expect { execute_node(configuration: configuration.deep_stringify_keys) }.to raise_error(
      DiscourseWorkflows::NodeError,
      message,
    )
    expect(a_request(:any, /#{Regexp.escape(instance_url)}/)).not_to have_been_made
  end

  describe "get" do
    let(:salesforce_response) do
      { attributes: { type: "Case" }, Id: record_id, Status: "New", Priority: "High" }
    end

    it "returns the record without its attributes" do
      request =
        stub_request(:get, "#{api_path}/Case/#{record_id}").to_return(
          status: 200,
          body: salesforce_response.to_json,
        )

      output = run(operation: "get", object: "Case", record_id: record_id)

      expect(request).to have_been_requested.once
      expect(output).to eq(
        "object" => "Case",
        "id" => record_id,
        "record" => {
          "Id" => record_id,
          "Status" => "New",
          "Priority" => "High",
        },
      )
    end

    it "requests only the listed fields" do
      request =
        stub_request(:get, "#{api_path}/Case/#{record_id}").with(
          query: {
            fields: "Status,Priority",
          },
        ).to_return(status: 200, body: salesforce_response.to_json)

      run(operation: "get", object: "Case", record_id: record_id, field_names: "Status, Priority")

      expect(request).to have_been_requested.once
    end
  end

  describe "update" do
    it "patches the record" do
      request =
        stub_request(:patch, "#{api_path}/Case/#{record_id}").with(
          body: { Status: "Working", Priority__c: "High" }.to_json,
        ).to_return(status: 204)

      output =
        run(
          update_config(
            [
              { "key" => "Status", "value" => "Working" },
              { "key" => "Priority__c", "value" => "High" },
            ],
          ),
        )

      expect(request).to have_been_requested.once
      expect(output).to eq(
        "object" => "Case",
        "id" => record_id,
        "fields" => {
          "Status" => "Working",
          "Priority__c" => "High",
        },
      )
    end
  end

  describe "validation" do
    it "rejects an invalid object name" do
      expect_node_error(
        { operation: "get", object: "Case/../User", record_id: record_id },
        /not a valid Salesforce object name/,
      )
    end

    it "rejects an invalid record id" do
      expect_node_error(
        { operation: "get", object: "Case", record_id: "abc?x=1" },
        /not a valid Salesforce record ID/,
      )
    end

    it "rejects an invalid field name in a get" do
      expect_node_error(
        {
          operation: "get",
          object: "Case",
          record_id: record_id,
          field_names: "Status,Id FROM User",
        },
        /not a valid Salesforce field name/,
      )
    end

    it "rejects an invalid field name in an update" do
      expect_node_error(
        update_config([{ "key" => "Status=1", "value" => "x" }]),
        /not a valid Salesforce field name/,
      )
    end

    it "does not request every field when the field list expression raises" do
      expect_node_error(
        {
          operation: "get",
          object: "Case",
          record_id: record_id,
          field_names: "={{ $json.missing.deeper }}",
        },
        /TypeError/,
      )
    end

    it "does not send null when an expression resolves to undefined" do
      expect_node_error(
        update_config([{ "key" => "Status", "value" => "={{ $json.missing }}" }]),
        /"Status" has no value/,
      )
    end

    it "does not send null when an expression raises" do
      expect_node_error(
        update_config([{ "key" => "Status", "value" => "={{ $json.missing.deeper }}" }]),
        /TypeError/,
      )
    end

    it "rejects an update without fields" do
      expect_node_error(update_config([]), /at least one field/)
    end
  end

  describe "Salesforce errors" do
    it "surfaces the message Salesforce returned" do
      stub_request(:patch, "#{api_path}/Case/#{record_id}").to_return(
        status: 400,
        body: [
          {
            message: "Required fields are missing: [Subject]",
            errorCode: "REQUIRED_FIELD_MISSING",
          },
        ].to_json,
      )

      expect {
        execute_node(configuration: update_config([{ "key" => "Subject", "value" => "" }]))
      }.to raise_error(DiscourseWorkflows::NodeError, /Required fields are missing/)
    end

    it "turns a connection failure into a node error" do
      stub_request(:patch, "#{api_path}/Case/#{record_id}").to_timeout

      expect {
        execute_node(configuration: update_config([{ "key" => "Status", "value" => "Working" }]))
      }.to raise_error(DiscourseWorkflows::NodeError, /Could not reach Salesforce/)
    end

    it "reports invalid credentials" do
      SiteSetting.salesforce_client_id = ""

      expect {
        execute_node(
          configuration: {
            "operation" => "get",
            "object" => "Case",
            "record_id" => record_id,
          },
        )
      }.to raise_error(DiscourseWorkflows::NodeError, /Salesforce credentials/)
    end
  end
end
