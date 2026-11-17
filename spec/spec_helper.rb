# frozen_string_literal: true

RSpec.shared_context "with salesforce spec helper" do
  let(:access_token) { "SALESFORCE_ACCESS_TOKEN" }
  let(:instance_url) { "https://test.my.salesforce.com/" }
  let(:api_response_status) { 200 }
  let(:api_response_body) { %({"access_token":"#{access_token}","instance_url":"#{instance_url}"}) }

  before do
    Discourse.redis.del(Salesforce::Api::ACCESS_TOKEN_KEY)
    Rails.cache.clear

    SiteSetting.salesforce_enabled = true
    SiteSetting.salesforce_instance_url = instance_url
    SiteSetting.salesforce_client_id = "SALESFORCE_CLIENT_ID"
    SiteSetting.salesforce_username = "SALESFORCE_API_USERNAME"
    SiteSetting.salesforce_rsa_private_key = "SALESFORCE_PRIVATE_KEY"

    Salesforce::Api.any_instance.stubs(:jwt_assertion).returns("SALESFORCE_PRIVATE_KEY")
    stub_request(:post, "https://login.salesforce.com/services/oauth2/token").with(
      body: {
        "assertion" => "SALESFORCE_PRIVATE_KEY",
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
      },
    ).to_return(status: api_response_status, body: api_response_body, headers: {})
  end

  def api_path
    "#{instance_url}services/data/v49.0/sobjects"
  end

  def query_path
    "#{instance_url}services/data/v49.0/query/"
  end

  def stub_salesforce_converted_lead_lookup(email, records: [])
    stub_request(:get, query_path).with(
      query: {
        q:
          "SELECT Id, IsConverted, ConvertedContactId FROM Lead WHERE Email = '#{email}' AND IsConverted = true",
      },
    ).to_return(body: { totalSize: records.size, records: records }.to_json)
  end

  def stub_salesforce_person_lookup(
    object_name,
    email,
    id: nil,
    fields: [],
    record: nil,
    records: nil
  )
    record ||= { Id: id } if id.present?
    records ||= record.present? ? [record] : []
    query_fields = ["Id", *fields.map(&:to_s)].uniq.join(",")
    conditions = ["Email = '#{email}'"]
    conditions << "IsConverted = false" if object_name == "Lead"

    stub_request(:get, query_path).with(
      query: {
        q: "SELECT #{query_fields} FROM #{object_name} WHERE #{conditions.join(" AND ")}",
      },
    ).to_return(
      status: 200,
      body: { totalSize: records.size, records: records }.to_json,
      headers: {
      },
    )
  end
end

RSpec.shared_context "with hubspot spec helper" do
  before do
    Rails.cache.clear
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
    SiteSetting.hubspot_enabled = true
    SiteSetting.hubspot_portal_id = "12345"
    SiteSetting.hubspot_access_token = "HUBSPOT_ACCESS_TOKEN"
  end

  def hubspot_url(path)
    "https://api.hubapi.com/crm/v3/#{path}"
  end

  def hubspot_contact(id, email, **properties)
    {
      "id" => id.to_s,
      "properties" => { "email" => email, "lastmodifieddate" => "2026-11-01T10:00:00.000Z" }.merge(
        properties.stringify_keys,
      ),
    }
  end

  def stub_hubspot_properties(names)
    stub_request(:get, hubspot_url("properties/contacts")).to_return(
      body: {
        results:
          names.map do |name|
            { name: name, label: name.humanize, type: "string", groupName: "contactinformation" }
          end,
      }.to_json,
    )
  end

  def stub_hubspot_contact_list(results, query: {}, after: nil)
    stub_request(:get, hubspot_url("objects/contacts")).with(
      query: hash_including(query),
    ).to_return(
      body: { results: results, paging: after ? { next: { after: after } } : nil }.compact.to_json,
    )
  end

  def stub_hubspot_contact_search(results, after: nil, status: 200, headers: {})
    stub_request(:post, hubspot_url("objects/contacts/search")).to_return(
      status: status,
      headers: headers,
      body: { results: results, paging: after ? { next: { after: after } } : nil }.compact.to_json,
    )
  end

  def stub_hubspot_batch_read(results)
    stub_request(:post, hubspot_url("objects/contacts/batch/read")).to_return(
      body: { results: results }.to_json,
    )
  end
end
