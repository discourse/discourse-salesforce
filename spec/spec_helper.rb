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
    SiteSetting.salesforce_consumer_key = "SALESFORCE_CONSUMER_KEY"
    SiteSetting.salesforce_username = "SALESFORCE_API_USERNAME"
    SiteSetting.salesforce_server_key_contents = "SALESFORCE_PRIVATE_KEY"

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
  let(:hubspot_properties) do
    [
      { name: "email", label: "Email", type: "string" },
      { name: "firstname", label: "First name", type: "string" },
      { name: "lastname", label: "Last name", type: "string" },
      { name: "community_posts", label: "Community posts", type: "number", hubspotDefined: false },
      {
        name: "community_source",
        label: "Community source",
        type: "string",
        hubspotDefined: false,
      },
    ]
  end

  before do
    Rails.cache.clear
    SiteSetting.salesforce_enabled = true
    SiteSetting.enable_guided_sync_configuration = true
    SiteSetting.hubspot_enabled = true
    SiteSetting.hubspot_portal_id = "12345"
    SiteSetting.hubspot_access_token = "HUBSPOT_ACCESS_TOKEN"
    stub_request(
      :post,
      "https://api.hubapi.com/oauth/v2/private-apps/get/access-token-info",
    ).to_return(body: { hubId: 12_345, appId: 6789 }.to_json)
    stub_request(:get, hubspot_url("properties/contacts")).to_return(
      body: { results: hubspot_properties }.to_json,
    )
  end

  after { Discourse.redis.without_namespace.del("hubspot_api:12345:6789:cooldown") }

  def hubspot_url(path = nil)
    ["https://api.hubapi.com/crm/v3", path].compact.join("/")
  end

  def hubspot_contact(id, email, **properties)
    {
      "id" => id.to_s,
      "properties" => { "email" => email, "lastmodifieddate" => "2026-11-01T10:00:00.000Z" }.merge(
        properties.stringify_keys,
      ),
    }
  end

  def hubspot_company(id, **properties)
    { "id" => id.to_s, "properties" => properties.stringify_keys }
  end

  def stub_hubspot_properties(names, object: "contact")
    stub_request(
      :get,
      hubspot_url("properties/#{::Hubspot::Api::OBJECT_PATHS.fetch(object)}"),
    ).to_return(
      body: {
        results:
          names.map do |name|
            { name: name, label: name.humanize, type: "string", groupName: "#{object}information" }
          end,
      }.to_json,
    )
  end

  def stub_hubspot_company_batch_read(results, ids: nil, errors: [])
    stub = stub_request(:post, hubspot_url("objects/companies/batch/read"))
    stub = stub.with(body: hash_including("inputs" => ids.map { |id| { "id" => id } })) if ids
    stub.to_return(
      status: errors.any? ? 207 : 200,
      body: { results: results, errors: errors }.to_json,
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
