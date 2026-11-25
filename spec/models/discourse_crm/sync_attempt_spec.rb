# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::SyncAttempt do
  fab!(:user)
  fab!(:configuration, :sync_configuration)
  let(:hubspot_configuration) { Fabricate(:hubspot_sync_configuration, account: "12345") }

  it "records recovery when a failed user's CRM record is already up to date" do
    configuration.record_result(user.id, error: StandardError.new)
    2.times { configuration.record_result(user.id, reason: "unchanged") }
    expect(described_class.order(:id).pluck(:reason)).to eq(%w[failed unchanged])
    expect(configuration.sync_states.find_by!(user_id: user.id).error).to be_nil
  end

  it "preserves the affected property for invalid HubSpot options" do
    attempt =
      described_class.record(
        hubspot_configuration,
        user.id,
        error: Hubspot::InvalidPropertyValue.new("lifecyclestage"),
      )
    expect(attempt.diagnostics).to eq(
      "codes" => ["INVALID_OPTION"],
      "properties" => ["lifecyclestage"],
    )
  end

  it "rolls back a success entry if updating sync status fails" do
    DiscourseCrm::SyncState
      .stubs(:where)
      .with(configuration_id: configuration.id, user_id: user.id)
      .raises(ActiveRecord::Deadlocked)
    expect { configuration.record_result(user.id, reason: "updated") }.to raise_error(
      ActiveRecord::Deadlocked,
    )
    expect(described_class.where(configuration_id: configuration.id)).to be_empty
    expect(configuration.reload.last_synced_at).to be_nil
  end

  it "retains failures when retries succeed and configurations are deleted" do
    error =
      Salesforce::InvalidApiResponse.new(
        [
          { errorCode: "REQUIRED_FIELD_MISSING", message: "secret mapped value", request: "token" },
        ].to_json,
        status: 400,
      )
    DiscourseCrm::SyncConfiguration.record_result(configuration.id, user.id, error: error)
    DiscourseCrm::SyncConfiguration.record_result(configuration.id, user.id)
    configuration.destroy!

    attempts = described_class.order(:id)
    expect(attempts.pluck(:outcome)).to eq(%w[failed success])
    expect(attempts.last.diagnostics).to eq({})
    expect(attempts.first.diagnostics).to eq("status" => 400, "codes" => ["REQUIRED_FIELD_MISSING"])
    expect(attempts.first.attributes.to_json).not_to include("secret mapped value", "token")
  end

  it "does not retain arbitrary exception messages or malformed provider bodies" do
    [
      StandardError.new("password=secret"),
      Salesforce::InvalidApiResponse.new("<html>secret</html>"),
    ].each do |error|
      attempt = described_class.record(configuration, user.id, error: error)
      expect(attempt.attributes.to_json).not_to include("secret")
    end
  end

  it "retains safe HubSpot diagnostics without response values" do
    error =
      Hubspot::InvalidApiResponse.new(
        {
          category: "VALIDATION_ERROR",
          correlationId: "trace-123",
          message: "token secret",
          errors: [
            {
              code: "INVALID_OPTION",
              message: "private value",
              context: {
                propertyName: ["status"],
              },
            },
          ],
        }.to_json,
        status: 400,
      )
    attempt = described_class.record(hubspot_configuration, user.id, error: error)
    expect(attempt.diagnostics).to include(
      "codes" => ["INVALID_OPTION"],
      "properties" => ["status"],
    )
    expect(attempt.attributes.to_json).not_to include("secret", "private value", "trace-123")
  end

  it "stores the specific validation reason and the rejected email" do
    validation = [
      {
        error: "INVALID_EMAIL",
        name: "email",
        message: "Private email is invalid",
        value: user.email,
      },
    ]
    error =
      Hubspot::InvalidApiResponse.from_response(
        {
          category: "VALIDATION_ERROR",
          message: "Property values were not valid: #{validation.to_json}",
        }.to_json,
        status: 400,
      )
    DiscourseCrm::SyncConfiguration.record_result(hubspot_configuration.id, user.id, error: error)
    attempt = described_class.last
    expect(attempt.diagnostics).to include("codes" => ["INVALID_EMAIL"], "properties" => ["email"])
    expect(attempt.diagnostics["rejected_values"]).to eq(
      [{ "property" => "email", "value" => user.email }],
    )
    expect(attempt.attributes.to_json).not_to include("Private email")
  end

  it "records an invalid email failure even when the rejected value contains a null byte" do
    error =
      Hubspot::ApiValidationError.new(
        { code: "INVALID_EMAIL", name: "email", value: "bad\0address" }.to_json,
        status: 400,
      )
    attempt = described_class.record(hubspot_configuration, user.id, error: error)
    expect(attempt.diagnostics).to include("codes" => ["INVALID_EMAIL"])
    expect(attempt.diagnostics).not_to have_key("rejected_values")
  end

  it "omits a rejected email when the response arrives after anonymization" do
    error =
      Hubspot::ApiValidationError.new(
        { code: "INVALID_EMAIL", name: "email", value: user.email }.to_json,
        status: 400,
      )
    UserAnonymizer.make_anonymous(user, Discourse.system_user)

    attempt = described_class.record(hubspot_configuration, user.id, error: error)

    expect(attempt.diagnostics).to include("codes" => ["INVALID_EMAIL"])
    expect(attempt.diagnostics).not_to have_key("rejected_values")
  end

  it "scrubs only the email that changes or is removed, even with sync disabled" do
    SiteSetting.salesforce_enabled = false
    SiteSetting.hubspot_enabled = false
    secondary = Fabricate(:secondary_email, user: user)
    attempts =
      [user.email, secondary.email].map do |email|
        error =
          Hubspot::ApiValidationError.new(
            { code: "INVALID_EMAIL", name: "email", value: email.upcase }.to_json,
          )
        described_class.record(hubspot_configuration, user.id, error: error)
      end
    user.primary_email.update!(email: "new@example.com")
    expect(attempts.first.reload.diagnostics).not_to have_key("rejected_values")
    expect(attempts.last.reload.diagnostics).to have_key("rejected_values")

    secondary.destroy!
    expect(attempts.last.reload.diagnostics).not_to have_key("rejected_values")
    expect(attempts.last.diagnostics.fetch("codes")).to eq(["INVALID_EMAIL"])
  end

  %i[user_anonymized user_destroyed].each do |event|
    it "scrubs the affected user's rejected values on #{event} with syncing disabled" do
      SiteSetting.salesforce_enabled = false
      SiteSetting.hubspot_enabled = false
      other_user = Fabricate(:user)
      attempts =
        [user, other_user].map do |member|
          error =
            Hubspot::InvalidApiResponse.new(
              { code: "INVALID_EMAIL", name: "email", value: member.email }.to_json,
            )
          described_class.record(hubspot_configuration, member.id, error: error)
        end

      if event == :user_anonymized
        DiscourseEvent.trigger(event, user: user, opts: {})
      else
        DiscourseEvent.trigger(event, user)
      end

      expect(attempts.first.reload.diagnostics).to eq(
        "codes" => ["INVALID_EMAIL"],
        "properties" => ["email"],
      )
      expect(attempts.last.reload.diagnostics.fetch("rejected_values")).to eq(
        [{ "property" => "email", "value" => other_user.email }],
      )
    end
  end

  it "filters provider diagnostics before writing activity history" do
    error = StandardError.new
    error.stubs(:sync_activity_diagnostics).returns(
      codes: ["FIELD_INVALID", "FIELD_INVALID", "private response text"],
      properties: [{ value: "secret" }],
      rejected_email: "invalid\0email",
      request_body: "secret",
    )
    expect(described_class.record(configuration, user.id, error: error).diagnostics).to eq(
      "codes" => ["FIELD_INVALID"],
    )
  end
end
