# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::GuidedSyncController do
  include_context "with salesforce spec helper"

  fab!(:admin)
  fab!(:group)
  fab!(:member) { Fabricate(:user, username: "alice", name: "Alice Morgan") }
  fab!(:other_member) { Fabricate(:user, username: "bruce", name: "Bruce Chen") }
  fab!(:outsider, :user)

  let(:configuration) do
    {
      group: group.name,
      object: "Contact",
      mappings: [
        { source: "last", destination: "LastName", policy: "keep" },
        { source: "static", value: "Discourse", destination: "LeadSource", policy: "overwrite" },
      ],
    }
  end

  before do
    SiteSetting.enable_guided_sync_configuration = true
    group.add(member)
    group.add(other_member)
    sign_in(admin)
    Jobs::SyncSalesforceUser.clear
    stub_request(:get, "#{api_path}/Contact/describe").to_return(
      body: {
        fields:
          %w[Email LastName LeadSource].map do |name|
            { name: name, type: "string", createable: true, updateable: true }
          end,
      }.to_json,
    )
  end

  it "searches only eligible group members and excludes suspended members" do
    other_member.update!(suspended_till: 1.day.from_now)
    get "/salesforce/admin/guided-sync/preview-users.json", params: { group: group.name }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["users"].pluck("id")).to eq([member.id])

    get "/salesforce/admin/guided-sync/preview-users.json",
        params: {
          group: group.name,
          q: "Morgan",
        }
    expect(response.parsed_body["users"].pluck("id")).to eq([member.id])
    get "/salesforce/admin/guided-sync/preview-users.json",
        params: {
          group: group.name,
          q: outsider.username,
        }
    expect(response.parsed_body["users"]).to eq([])
  end

  it "previews the union of selected groups without duplicate users" do
    second_group = Fabricate(:group)
    second_group.add(member)
    second_group.add(outsider)
    get "/salesforce/admin/guided-sync/preview-users.json",
        params: {
          groups: [group.name, second_group.name],
        }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["users"].pluck("id")).to contain_exactly(
      member.id,
      other_member.id,
      outsider.id,
    )

    post "/salesforce/admin/guided-sync/preview.json",
         params: {
           configuration:
             configuration.except(:group).merge(groups: [group.name, second_group.name]),
           user_id: outsider.id,
         }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("user", "id")).to eq(outsider.id)
  end

  it "previews the first eligible member using real values without writes or saved links" do
    post "/salesforce/admin/guided-sync/preview.json", params: { configuration: configuration }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["user"]["id"]).to eq(member.id)
    expect(response.parsed_body["rows"]).to include(
      {
        "field" => "LastName",
        "current" => "Taylor",
        "incoming" => "Morgan",
        "result" => "Taylor",
        "outcome" => "kept",
      },
      {
        "field" => "LeadSource",
        "current" => "Web",
        "incoming" => "Discourse",
        "result" => "Discourse",
        "outcome" => "updated",
      },
    )
    expect(
      PluginStore.get(Salesforce::PLUGIN_NAME, "configured_user_link:Contact:#{member.id}"),
    ).to be_nil
    expect(member.reload.salesforce_contact_id).to be_nil
    expect(a_request(:post, %r{/services/data/})).not_to have_been_made
    expect(a_request(:patch, %r{/services/data/})).not_to have_been_made
    expect(Jobs::SyncSalesforceUser.jobs).to be_empty
  end

  it "uses real selected member values and samples even when a Salesforce record is linked" do
    PluginStore.set(
      Salesforce::PLUGIN_NAME,
      "configured_user_link:Contact:#{other_member.id}",
      { id: "contact1", instance: instance_url },
    )
    post "/salesforce/admin/guided-sync/preview.json",
         params: {
           configuration: configuration,
           user_id: other_member.id,
         }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["rows"]).to include(
      {
        "field" => "Email",
        "current" => "member@example.com",
        "incoming" => other_member.email,
        "result" => "member@example.com",
        "outcome" => "kept",
      },
      {
        "field" => "LastName",
        "current" => "Taylor",
        "incoming" => "Chen",
        "result" => "Taylor",
        "outcome" => "kept",
      },
      {
        "field" => "LeadSource",
        "current" => "Web",
        "incoming" => "Discourse",
        "result" => "Discourse",
        "outcome" => "updated",
      },
    )
    expect(a_request(:get, %r{/query/})).not_to have_been_made
    expect(a_request(:get, "#{api_path}/Contact/contact1")).not_to have_been_made
    expect(a_request(:patch, %r{/services/data/})).not_to have_been_made
    expect(other_member.reload.salesforce_contact_id).to be_nil
  end

  it "returns a sample preview for an empty group and rejects members outside its scope" do
    group.remove(member)
    group.remove(other_member)
    post "/salesforce/admin/guided-sync/preview.json", params: { configuration: configuration }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["sample"]).to eq(true)
    expect(response.parsed_body["user"]).to be_nil
    expect(response.parsed_body["rows"]).to include(
      hash_including("field" => "LastName", "incoming" => "Morgan", "result" => "Taylor"),
      hash_including("field" => "LeadSource", "incoming" => "Discourse", "result" => "Discourse"),
    )
    post "/salesforce/admin/guided-sync/preview.json",
         params: {
           configuration: configuration,
           user_id: outsider.id,
         }
    expect(response).to have_http_status(:not_found)
    expect(a_request(:post, %r{/services/data/})).not_to have_been_made
  end

  it "reports field metadata failures without exposing upstream details" do
    stub_request(:get, "#{api_path}/Contact/describe").to_return(
      status: 503,
      body: "private upstream details",
    )
    post "/salesforce/admin/guided-sync/preview.json", params: { configuration: configuration }
    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body["errors"]).to eq([I18n.t("salesforce.error.connection.temporary")])
  end

  it "restricts previews to admins and the feature flag and validates mappings and objects" do
    post "/salesforce/admin/guided-sync/preview.json",
         params: {
           configuration: configuration.merge(object: "Account"),
         }
    expect(response).to have_http_status(:bad_request)
    post "/salesforce/admin/guided-sync/preview.json",
         params: {
           configuration:
             configuration.merge(
               mappings: [{ source: "password", destination: "LastName", policy: "overwrite" }],
             ),
         }
    expect(response).to have_http_status(:bad_request)
    SiteSetting.enable_guided_sync_configuration = false
    post "/salesforce/admin/guided-sync/preview.json", params: { configuration: configuration }
    expect(response).to have_http_status(:not_found)
    get "/salesforce/admin/guided-sync/preview-users.json", params: { group: group.name }
    expect(response).to have_http_status(:not_found)

    SiteSetting.enable_guided_sync_configuration = true
    sign_in(outsider)
    post "/salesforce/admin/guided-sync/preview.json", params: { configuration: configuration }
    expect(response).to have_http_status(:forbidden)
    get "/salesforce/admin/guided-sync/preview-users.json", params: { group: group.name }
    expect(response).to have_http_status(:forbidden)
  end
end
