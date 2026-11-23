# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Hubspot::InvalidApiResponse do
  it "returns diagnostic codes for recognized batch errors and ignores unknown messages" do
    expect(described_class.new("Contact requires individual reconciliation").diagnostics).to eq(
      codes: ["BATCH_RESULT_UNCONFIRMED"],
    )
    expect(described_class.new("Invalid contact batch write response").diagnostics).to eq(
      codes: ["INVALID_BATCH_WRITE_RESPONSE"],
    )
    expect(described_class.new("Invalid contact batch read response").diagnostics).to eq(
      codes: ["INVALID_BATCH_READ_RESPONSE"],
    )
    expect(described_class.new("secret request contents").diagnostics).to eq({})
  end

  def validation_message
    "Property values were not valid: " +
      [
        {
          isValid: false,
          message: "Email address private@example.invalid is invalid",
          error: "INVALID_EMAIL",
          name: "email",
          value: "private@example.invalid",
        },
      ].to_json
  end

  it "extracts validation codes and properties embedded in a top-level message" do
    error =
      described_class.from_response(
        { category: "VALIDATION_ERROR", message: validation_message }.to_json,
        status: 400,
      )

    expect(error.diagnostics).to eq(
      category: ["VALIDATION_ERROR"],
      codes: ["INVALID_EMAIL"],
      properties: ["email"],
    )
  end

  it "extracts embedded errors from batch results alongside structured errors" do
    error =
      described_class.new(
        {
          category: "VALIDATION_ERROR",
          errors: [
            { message: validation_message },
            { code: "INVALID_INTEGER", context: { propertyName: ["age"] } },
          ],
        }.to_json,
      )

    expect(error.diagnostics).to include(
      codes: %w[INVALID_INTEGER INVALID_EMAIL],
      properties: %w[age email],
    )
  end

  it "extracts the rejected email from an embedded message and keeps it out of diagnostics" do
    error =
      described_class.new(
        {
          message:
            "Property values were not valid: " +
              [
                {
                  error: "INVALID_EMAIL",
                  name: "email",
                  message: "Email address jane@invalid.example is invalid",
                },
              ].to_json,
        }.to_json,
      )
    expect(error.rejected_email).to eq("jane@invalid.example")
    expect(error.diagnostics.to_json).not_to include("jane@invalid.example")
  end

  it "ignores unrelated property values and free-form messages when extracting a rejected email" do
    error =
      described_class.new(
        {
          errors: [
            { code: "INVALID_OPTION", name: "access_token", value: "secret" },
            { code: "INVALID_EMAIL", name: "email", message: "Authorization: Bearer secret" },
          ],
        }.to_json,
      )
    expect(error.rejected_email).to be_nil
  end

  it "preserves safe diagnostics when an embedded message is malformed or has an unexpected shape" do
    ["not JSON", "{}"].each do |value|
      error =
        described_class.new(
          {
            category: "VALIDATION_ERROR",
            message: "Property values were not valid: #{value}",
            errors: [{ code: "INVALID_OPTION", name: "status" }],
          }.to_json,
        )
      expect(error.diagnostics).to include(
        category: ["VALIDATION_ERROR"],
        codes: ["INVALID_OPTION"],
        properties: ["status"],
      )
    end
  end
end
