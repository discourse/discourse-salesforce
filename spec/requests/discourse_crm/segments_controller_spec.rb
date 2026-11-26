# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::SegmentsController do
  include_context "with hubspot spec helper"

  fab!(:admin)
  fab!(:user)
  fab!(:group) { Fabricate(:group, name: "enterprise") }

  let(:conditions) do
    {
      all: [
        {
          id: 1,
          object: "company",
          property: "plan_tier",
          operator: "contains",
          value: "enterprise",
        },
      ],
    }
  end

  let!(:configuration) do
    Fabricate(
      :hubspot_sync_configuration,
      mappings: [
        { "id" => 1, "object" => "contact", "source" => "jobtitle" },
        { "id" => 2, "object" => "company", "source" => "plan_tier" },
      ],
    )
  end

  before do
    stub_hubspot_properties(%w[jobtitle])
    stub_hubspot_properties(%w[plan_tier], object: "company")
    SiteSetting.crm_segments_enabled = true
    sign_in(admin)
  end

  describe "#index" do
    it "lists segments with their state, the pull configurations, their properties and the syncable groups" do
      segment = Fabricate(:crm_segment, configuration:, group_id: group.id, remove_unmatched: true)
      segment.members.create!(user:)

      get "/salesforce/admin/guided-sync/segments.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["segments"]).to eq(
        [
          {
            "id" => segment.id,
            "name" => "Enterprise customers",
            "configuration_id" => configuration.id,
            "configuration_name" => "Import contacts",
            "conditions" => segment.conditions,
            "group_id" => group.id,
            "group_name" => "enterprise",
            "remove_unmatched" => true,
            "member_count" => 1,
            "last_evaluated_at" => nil,
            "connection_changed" => false,
            "missing_properties" => [],
          },
        ],
      )
      expect(response.parsed_body["configurations"]).to eq(
        [{ "id" => configuration.id, "name" => "Import contacts", "provider" => "hubspot" }],
      )
      expect(response.parsed_body["properties"]).to eq(
        [
          {
            "id" => "contact.jobtitle",
            "configuration_id" => configuration.id,
            "object" => "contact",
            "name" => "jobtitle",
            "label" => "Jobtitle",
          },
          {
            "id" => "company.plan_tier",
            "configuration_id" => configuration.id,
            "object" => "company",
            "name" => "plan_tier",
            "label" => "Plan tier",
          },
        ],
      )
      expect(response.parsed_body["groups"].map { |item| item["name"] }).to include("enterprise")
      expect(response.parsed_body["groups"].map { |item| item["id"] }).not_to include(
        *Group::AUTO_GROUP_IDS.keys,
      )
    end

    it "flags a segment whose pull was configured under a previous portal" do
      segment = Fabricate(:crm_segment, configuration:)
      configuration.update_columns(account: "99999")

      get "/salesforce/admin/guided-sync/segments.json"

      expect(response.parsed_body["configurations"]).to be_empty
      expect(response.parsed_body["segments"].first).to include(
        "id" => segment.id,
        "connection_changed" => true,
      )
    end

    it "falls back to property names and flags stale conditions when HubSpot is unreachable" do
      stub_request(:get, hubspot_url("properties/companies")).to_return(status: 500)
      segment =
        Fabricate(
          :crm_segment,
          configuration:,
          conditions: {
            "all" => [
              { "id" => 1, "object" => "contact", "property" => "city", "operator" => "set" },
            ],
          },
        )

      get "/salesforce/admin/guided-sync/segments.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["properties"].map { |item| item["label"] }).to eq(
        %w[jobtitle plan_tier],
      )
      expect(response.parsed_body["segments"].first).to include(
        "id" => segment.id,
        "missing_properties" => ["contact.city"],
      )
    end

    it "is hidden from non-admins and while the feature is off" do
      sign_in(user)
      get "/salesforce/admin/guided-sync/segments.json"
      expect(response.status).to eq(403)

      sign_in(admin)
      SiteSetting.enable_guided_sync_configuration = false
      get "/salesforce/admin/guided-sync/segments.json"
      expect(response.status).to eq(404)

      SiteSetting.enable_guided_sync_configuration = true
      SiteSetting.crm_segments_enabled = false
      get "/salesforce/admin/guided-sync/segments.json"
      expect(response.status).to eq(404)
      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "Enterprise",
             conditions:,
           },
           as: :json
      expect(response.status).to eq(404)
    end
  end

  describe "#create" do
    it "creates a segment and returns it" do
      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "Enterprise",
             conditions:,
             group_id: group.id,
             remove_unmatched: true,
           },
           as: :json

      expect(response.status).to eq(201)
      expect(response.parsed_body).to include(
        "name" => "Enterprise",
        "group_name" => "enterprise",
        "remove_unmatched" => true,
        "member_count" => 0,
        "missing_properties" => [],
      )
      expect(DiscourseCrm::Segment.find(response.parsed_body["id"]).configuration).to eq(
        configuration,
      )
    end

    it "rejects a blank name with a 400" do
      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "",
             conditions:,
           },
           as: :json

      expect(response.status).to eq(400)
      expect(response.parsed_body["errors"]).to eq(["Name can't be blank"])
    end

    it "rejects an automatic group, a taken group and an unpulled property with a 422" do
      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "Staff",
             conditions:,
             group_id: Group::AUTO_GROUPS[:staff],
           },
           as: :json
      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(["Group cannot be an automatic group"])

      Fabricate(:crm_segment, configuration:, group_id: group.id)
      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "Second segment",
             conditions:,
             group_id: group.id,
           },
           as: :json
      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(["Group is already targeted by another segment"])

      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "Cities",
             conditions: {
               all: [{ id: 1, object: "contact", property: "city", operator: "set" }],
             },
           },
           as: :json
      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        ["contact.city is not pulled from the CRM. Add it to the pull or remove the condition."],
      )
    end

    it "rejects a condition that is not an object with a 422" do
      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "Broken",
             conditions: {
               all: ["plan_tier is set"],
             },
           },
           as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        ["Conditions must have at least one complete condition"],
      )
    end

    it "reports a group taken by a concurrent save as a validation error" do
      DiscourseCrm::Segment.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique)

      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "Racing",
             conditions:,
             group_id: group.id,
           },
           as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(["Group is already targeted by another segment"])
    end

    it "refuses to create a segment without a pull" do
      DiscourseCrm::SyncConfiguration.delete_all

      post "/salesforce/admin/guided-sync/segments.json",
           params: {
             configuration_id: configuration.id,
             name: "Enterprise",
             conditions:,
           },
           as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        ["Set up a pull from the CRM before defining segments."],
      )
    end
  end

  describe "#update" do
    it "updates the segment and keeps its pull configuration" do
      segment = Fabricate(:crm_segment, configuration:)

      put "/salesforce/admin/guided-sync/segments/#{segment.id}.json",
          params: {
            configuration_id: -1,
            name: "Renamed",
            conditions:,
            group_id: group.id,
          },
          as: :json

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include(
        "id" => segment.id,
        "name" => "Renamed",
        "configuration_id" => configuration.id,
        "group_id" => group.id,
      )
    end

    it "returns 404 for an unknown segment" do
      put "/salesforce/admin/guided-sync/segments/0.json", params: { name: "Renamed", conditions: }

      expect(response.status).to eq(404)
    end
  end

  describe "#destroy" do
    it "deletes the segment" do
      segment = Fabricate(:crm_segment, configuration:)

      delete "/salesforce/admin/guided-sync/segments/#{segment.id}.json"

      expect(response.status).to eq(204)
      expect(DiscourseCrm::Segment.exists?(segment.id)).to eq(false)
    end

    it "returns 404 for an unknown segment" do
      delete "/salesforce/admin/guided-sync/segments/0.json"

      expect(response.status).to eq(404)
    end
  end

  describe "#preview" do
    it "counts the users matching the given conditions" do
      Fabricate(
        :crm_record,
        object: "company",
        external_id: "acme",
        data: {
          "plan_tier" => "Enterprise",
        },
      )
      Fabricate(
        :crm_record,
        external_id: "501",
        company_external_id: "acme",
        data: {
          "jobtitle" => "CTO",
        },
      )
      DiscourseCrm::RecordLink.link_many!(
        [
          {
            provider: "hubspot",
            account: "12345",
            object: "contact",
            direction: "inbound",
            user_id: user.id,
            external_id: "501",
          },
        ],
      )

      post "/salesforce/admin/guided-sync/segments/preview.json",
           params: {
             configuration_id: configuration.id,
             conditions:,
           },
           as: :json

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq("count" => 1, "total" => 1, "usernames" => [user.username])
    end

    it "rejects malformed conditions with a 422" do
      post "/salesforce/admin/guided-sync/segments/preview.json",
           params: {
             configuration_id: configuration.id,
             conditions: {
               all: [{ object: "contact" }],
             },
           },
           as: :json

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(
        ["Conditions must have at least one complete condition"],
      )
    end
  end
end
