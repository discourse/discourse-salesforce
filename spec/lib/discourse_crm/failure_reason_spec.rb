# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::FailureReason do
  def message(provider, error_class: nil, **diagnostics)
    attempt =
      DiscourseCrm::SyncAttempt.new(
        provider: provider,
        error_class: error_class,
        diagnostics: diagnostics.stringify_keys,
      )
    described_class.for(attempt)
  end

  def translated(key, **options)
    I18n.t!("discourse_crm.sync_activity.errors.#{key}", **options)
  end

  it "prioritizes known codes and combines distinct explanations" do
    expect(
      message(
        "hubspot",
        codes: %w[INVALID_EMAIL INVALID_NUMBER INVALID_INTEGER],
        category: "VALIDATION_ERROR",
        status: 400,
      ),
    ).to eq("#{translated(:invalid_email)} #{translated(:invalid_number)}")
  end

  it "recognizes both historical HubSpot category formats" do
    expect(message("hubspot", category: "CONFLICT")).to eq(translated(:duplicate_value))
    expect(message("hubspot", category: ["MISSING_SCOPES"])).to eq(translated(:permissions))
  end

  it "includes only safe property names in an invalid-option message" do
    expect(
      message(
        "hubspot",
        error_class: "Hubspot::InvalidPropertyValue",
        codes: ["INVALID_OPTION"],
        properties: ["lifecyclestage", "private request body"],
      ),
    ).to eq(translated(:invalid_option_property, property: "lifecyclestage"))
  end

  it "resolves HubSpot batch failures and company lookup errors" do
    {
      "CONTACT_SEARCH_LIMIT" => :contact_search_limit,
      "BATCH_RESULT_UNCONFIRMED" => :batch_unconfirmed,
      "INCOMPLETE_COMPANY_BATCH_READ" => :incomplete_company_batch_read,
      "UNEXPECTED_COMPANY" => :unexpected_company,
      "CONFLICTING_COMPANY_IDS" => :conflicting_company_ids,
    }.each { |code, key| expect(message("hubspot", codes: [code])).to eq(translated(key)) }
  end

  it "resolves Salesforce codes and scopes them to that provider" do
    {
      "MALFORMED_ID" => :malformed_id,
      "UNABLE_TO_LOCK_ROW" => :locked_record,
      "INVALID_TYPE" => :unavailable_object,
      "DUPLICATES_DETECTED" => :duplicate_detected,
    }.each do |code, key|
      expect(message("salesforce", codes: [code], status: 400)).to eq(translated(key))
    end
    expect(message("hubspot", codes: ["INVALID_TYPE"])).to eq(
      translated(:provider_code, code: "INVALID_TYPE"),
    )
  end

  it "preserves safe unknown codes ahead of a generic category" do
    expect(
      message(
        "hubspot",
        codes: ["NEW_CODE", "NEW_CODE", "private value"],
        category: "VALIDATION_ERROR",
      ),
    ).to eq(translated(:provider_code, code: "NEW_CODE"))
  end

  it "gives a registered provider HTTP explanations without custom rules" do
    stub_const(DiscourseCrm::SyncConfiguration, :PROVIDERS, { "new_crm" => Class.new }) do
      expect(message("new_crm", status: 429)).to eq(translated(:rate_limit))
    end
  end

  it "uses provider exceptions, HTTP status and a generic fallback when codes are absent" do
    expect(
      message(
        "salesforce",
        error_class: "Salesforce::ConfiguredUserBatchSync::UnconfirmedCollectionResult",
      ),
    ).to eq(translated(:salesforce_unconfirmed))
    expect(message("hubspot", error_class: "Hubspot::InvalidApiResponse")).to eq(
      translated(:hubspot_unconfirmed),
    )
    expect(message("hubspot", error_class: "Hubspot::InvalidApiResponse", status: 404)).to eq(
      translated(:not_found),
    )
    expect(message("retired", error_class: "Faraday::TimeoutError")).to eq(translated(:timeout))
    expect(message("retired", status: 503)).to eq(translated(:temporary))
    expect(message("retired")).to eq(translated(:unknown))
  end
end
