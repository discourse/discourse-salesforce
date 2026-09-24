# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ::Salesforce::Associations do
  include_context "with salesforce spec helper"

  fab!(:linked_user, :user)
  fab!(:stale_user, :user)
  fab!(:contacts_group, :group)
  fab!(:leads_group, :group)

  let(:live_contact_id) { "003000000000001" }
  let(:dead_contact_id) { "003000000000002" }
  let(:dead_default_contact_id) { "003000000000003" }
  let(:dead_lead_id) { "00Q000000000001" }
  let(:live_case_id) { "500000000000001" }
  let(:dead_case_id) { "500000000000002" }

  before do
    SiteSetting.salesforce_contacts_group_id = contacts_group.id
    SiteSetting.salesforce_leads_group_id = leads_group.id
  end

  describe ".prune_dead!" do
    it "removes only references the connected org does not recognize" do
      linked_user.upsert_custom_fields(::Salesforce::Contact::ID_FIELD => live_contact_id)
      stale_user.upsert_custom_fields(
        ::Salesforce::Contact::ID_FIELD => dead_contact_id,
        ::Salesforce::Lead::ID_FIELD => dead_lead_id,
      )
      contacts_group.add(stale_user)
      leads_group.add(stale_user)
      SiteSetting.salesforce_default_contact_id_for_case_sync = dead_default_contact_id

      live_case = Fabricate(:salesforce_case, uid: live_case_id)
      live_case.topic.upsert_custom_fields(::CaseMixin::HAS_SALESFORCE_CASE => true)
      dead_case = Fabricate(:salesforce_case, uid: dead_case_id)
      dead_case.topic.upsert_custom_fields(::CaseMixin::HAS_SALESFORCE_CASE => true)
      dead_case_post = Fabricate(:post, topic: dead_case.topic)
      dead_case_post.upsert_custom_fields(::Salesforce::CaseComment::ID_FIELD => "00a000000000001")
      uidless_case = ::Salesforce::Case.create!(topic_id: Fabricate(:topic).id)

      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: "#{live_contact_id},#{dead_contact_id}",
        },
      ).to_return(status: 200, body: [{ "Id" => "#{live_contact_id}AAA" }, nil].to_json)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: dead_default_contact_id,
        },
      ).to_return(status: 200, body: [nil].to_json)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Lead").with(
        query: {
          fields: "Id",
          ids: dead_lead_id,
        },
      ).to_return(status: 200, body: [nil].to_json)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Case").with(
        query: {
          fields: "Id",
          ids: "#{live_case_id},#{dead_case_id}",
        },
      ).to_return(status: 200, body: [{ "Id" => "#{live_case_id}AAA" }, nil].to_json)

      counts = described_class.prune_dead!

      expect(counts).to eq(users: 2, posts: 1, cases: 2, settings: 1)
      expect(linked_user.reload.salesforce_contact_id).to eq(live_contact_id)
      expect(stale_user.reload.salesforce_contact_id).to eq(nil)
      expect(stale_user.salesforce_lead_id).to eq(nil)
      expect(contacts_group.users.exists?(stale_user.id)).to eq(false)
      expect(leads_group.users.exists?(stale_user.id)).to eq(false)
      expect(SiteSetting.salesforce_default_contact_id_for_case_sync).to eq("")
      expect(::Salesforce::Case.exists?(live_case.id)).to eq(true)
      expect(::Salesforce::Case.exists?(dead_case.id)).to eq(false)
      expect(::Salesforce::Case.exists?(uidless_case.id)).to eq(false)
      expect(live_case.topic.reload.has_salesforce_case).to eq(true)
      expect(dead_case.topic.reload.has_salesforce_case).to eq(false)
      expect(dead_case_post.reload.custom_fields[::Salesforce::CaseComment::ID_FIELD]).to eq(nil)
    end

    it "preserves a user link replaced while Salesforce is responding" do
      stale_user.upsert_custom_fields(::Salesforce::Contact::ID_FIELD => dead_contact_id)
      contacts_group.add(stale_user)
      field = stale_user.user_custom_fields.find_by(name: ::Salesforce::Contact::ID_FIELD)

      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact")
        .with(query: { fields: "Id", ids: dead_contact_id })
        .to_return do
          field.update!(value: live_contact_id)
          { status: 200, body: [nil].to_json }
        end

      expect(described_class.prune_dead![:users]).to eq(0)
      expect(field.reload.value).to eq(live_contact_id)
      expect(contacts_group.users.exists?(stale_user.id)).to eq(true)
    end

    it "preserves case metadata when a live replacement appears during lookup" do
      dead_case = Fabricate(:salesforce_case, uid: dead_case_id)
      dead_case.topic.upsert_custom_fields(::CaseMixin::HAS_SALESFORCE_CASE => true)
      post = Fabricate(:post, topic: dead_case.topic)
      post.upsert_custom_fields(::Salesforce::CaseComment::ID_FIELD => "00a000000000001")
      replacement = nil

      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Case")
        .with(query: { fields: "Id", ids: dead_case_id })
        .to_return do
          dead_case.destroy!
          replacement = Fabricate(:salesforce_case, topic: dead_case.topic, uid: live_case_id)
          { status: 200, body: [nil].to_json }
        end

      expect(described_class.prune_dead![:cases]).to eq(0)
      expect(::Salesforce::Case.exists?(replacement.id)).to eq(true)
      expect(dead_case.topic.reload.has_salesforce_case).to eq(true)
      expect(post.reload.custom_fields[::Salesforce::CaseComment::ID_FIELD]).to be_present
    end

    it "preserves a default contact changed while Salesforce is responding" do
      SiteSetting.salesforce_default_contact_id_for_case_sync = dead_default_contact_id

      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact")
        .with(query: { fields: "Id", ids: dead_default_contact_id })
        .to_return do
          SiteSetting.salesforce_default_contact_id_for_case_sync = live_contact_id
          { status: 200, body: [nil].to_json }
        end

      expect(described_class.prune_dead![:settings]).to eq(0)
      expect(SiteSetting.salesforce_default_contact_id_for_case_sync).to eq(live_contact_id)
    end

    it "isolates and removes IDs Salesforce rejects as malformed" do
      checksum_invalid = "003DEMOCONTACT0001"
      linked_user.upsert_custom_fields(::Salesforce::Contact::ID_FIELD => live_contact_id)
      stale_user.upsert_custom_fields(::Salesforce::Contact::ID_FIELD => checksum_invalid)

      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: "#{live_contact_id},#{checksum_invalid}",
        },
      ).to_return(
        status: 400,
        body: %([{"errorCode":"MALFORMED_ID","message":"malformed id #{checksum_invalid}"}]),
      )
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: live_contact_id,
        },
      ).to_return(status: 200, body: [{ "Id" => "#{live_contact_id}AAA" }].to_json)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: checksum_invalid,
        },
      ).to_return(
        status: 400,
        body: %([{"errorCode":"MALFORMED_ID","message":"malformed id #{checksum_invalid}"}]),
      )

      expect(described_class.prune_dead![:users]).to eq(1)
      expect(linked_user.reload.salesforce_contact_id).to eq(live_contact_id)
      expect(stale_user.reload.salesforce_contact_id).to eq(nil)
    end

    it "removes malformed local IDs without sending them to Salesforce" do
      stale_user.upsert_custom_fields(::Salesforce::Contact::ID_FIELD => "not-an-id")

      expect(described_class.prune_dead![:users]).to eq(1)
      expect(stale_user.reload.salesforce_contact_id).to eq(nil)
      expect(
        a_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact"),
      ).not_to have_been_made
    end

    it "leaves local references and raises when Salesforce rejects a lookup" do
      stale_user.upsert_custom_fields(::Salesforce::Contact::ID_FIELD => dead_contact_id)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: dead_contact_id,
        },
      ).to_return(status: 400, body: %([{"errorCode":"INVALID_FIELD","message":"invalid field"}]))

      expect { described_class.prune_dead! }.to raise_error(::Salesforce::InvalidApiResponse)
      expect(stale_user.reload.salesforce_contact_id).to eq(dead_contact_id)
    end

    it "preserves local references when Salesforce returns a different record" do
      stale_user.upsert_custom_fields(::Salesforce::Contact::ID_FIELD => dead_contact_id)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: dead_contact_id,
        },
      ).to_return(status: 200, body: [{ "Id" => live_contact_id }].to_json)

      expect { described_class.prune_dead! }.to raise_error(::Salesforce::InvalidApiResponse)
      expect(stale_user.reload.salesforce_contact_id).to eq(dead_contact_id)
    end
  end
end
