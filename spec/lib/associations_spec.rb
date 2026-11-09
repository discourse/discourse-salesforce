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

  describe ".unlink_contact!" do
    let(:scope) do
      { provider: "salesforce", account: instance_url, object: "Contact", user_id: stale_user.id }
    end

    it "removes matching local associations and only their Contact sync state and membership" do
      stale_user.upsert_custom_fields(
        Salesforce::Contact::ID_FIELD => dead_contact_id,
        Salesforce::Lead::ID_FIELD => dead_lead_id,
        "unrelated" => "retained",
      )
      contacts_group.add(stale_user)
      leads_group.add(stale_user)
      Salesforce::RecordLink.link!(**scope, external_id: dead_contact_id)
      other_account =
        Salesforce::RecordLink.link!(**scope.merge(account: "other"), external_id: dead_contact_id)
      other_user =
        Salesforce::RecordLink.link!(
          **scope.merge(user_id: linked_user.id),
          external_id: dead_contact_id,
        )
      converted_lead =
        Salesforce::RecordLink.mark_converted!(
          **scope.merge(object: "Lead"),
          external_id: dead_lead_id,
          to_object: "Contact",
          to_id: dead_contact_id,
        )
      salesforce_case = Fabricate(:salesforce_case, uid: dead_case_id)
      configurations = {
        contact: Fabricate(:sync_configuration, object: "Contact", account: instance_url),
        lead: Fabricate(:sync_configuration, object: "Lead", account: instance_url),
        other: Fabricate(:sync_configuration, object: "Contact", account: "other"),
      }
      configurations.each_value do |configuration|
        Salesforce::SyncState.store(configuration.id, stale_user.id, fingerprint: "old")
        Salesforce::SyncState.store(configuration.id, linked_user.id, fingerprint: "other-user")
      end

      expect(described_class.unlink_contact!(user: stale_user, expected_id: dead_contact_id)).to eq(
        true,
      )

      expect(stale_user.reload.salesforce_contact_id).to be_nil
      expect(stale_user.salesforce_lead_id).to eq(dead_lead_id)
      expect(stale_user.custom_fields["unrelated"]).to eq("retained")
      expect(Salesforce::RecordLink.find_by(**scope)).to be_nil
      expect(
        Salesforce::RecordLink.where(
          id: [other_account.id, other_user.id, converted_lead.id],
        ).count,
      ).to eq(3)
      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
      expect(contacts_group.users.exists?(stale_user.id)).to eq(false)
      expect(leads_group.users.exists?(stale_user.id)).to eq(true)
      expect(
        configurations.transform_values do |configuration|
          Salesforce::SyncState.find_by(
            configuration: configuration,
            user_id: stale_user.id,
          ).fingerprint
        end,
      ).to eq(contact: nil, lead: "old", other: "old")
      expect(Salesforce::SyncState.where(user_id: linked_user.id).pluck(:fingerprint).uniq).to eq(
        ["other-user"],
      )
      expect(a_request(:any, /salesforce\.com/)).not_to have_been_made
    end

    it "cleans a matching guided-only association on retry" do
      Salesforce::RecordLink.link!(**scope, external_id: dead_contact_id)
      contacts_group.add(stale_user)

      expect(described_class.unlink_contact!(user: stale_user, expected_id: dead_contact_id)).to eq(
        true,
      )
      expect(Salesforce::RecordLink.find_by(**scope)).to be_nil
      expect(contacts_group.users.exists?(stale_user.id)).to eq(false)
    end

    it "leaves unrelated state and converted links untouched when already unlinked" do
      contacts_group.add(stale_user)
      converted =
        Salesforce::RecordLink.mark_converted!(
          **scope,
          external_id: dead_contact_id,
          to_object: "Contact",
          to_id: live_contact_id,
        )
      configuration = Fabricate(:sync_configuration, object: "Contact", account: instance_url)
      Salesforce::SyncState.store(configuration.id, stale_user.id, fingerprint: "old")

      expect(described_class.unlink_contact!(user: stale_user, expected_id: dead_contact_id)).to eq(
        false,
      )
      expect(converted.reload.converted_to_id).to eq(live_contact_id)
      expect(contacts_group.users.exists?(stale_user.id)).to eq(true)
      expect(
        Salesforce::SyncState.find_by(
          configuration: configuration,
          user_id: stale_user.id,
        ).fingerprint,
      ).to eq("old")
    end

    it "preserves all associations and sync state if any stored ID differs" do
      [dead_contact_id, live_contact_id].each do |id|
        UserCustomField.create!(user: stale_user, name: Salesforce::Contact::ID_FIELD, value: id)
      end
      Salesforce::RecordLink.link!(**scope, external_id: dead_contact_id)
      contacts_group.add(stale_user)

      expect {
        described_class.unlink_contact!(user: stale_user, expected_id: dead_contact_id)
      }.to raise_error(described_class::ContactLinkChanged)
      expect(
        stale_user.user_custom_fields.where(name: Salesforce::Contact::ID_FIELD).pluck(:value),
      ).to contain_exactly(dead_contact_id, live_contact_id)
      expect(Salesforce::RecordLink.find_by(**scope).external_id).to eq(dead_contact_id)
      expect(contacts_group.users.exists?(stale_user.id)).to eq(true)
    end
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
      expect(leads_group.users.exists?(stale_user.id)).to eq(true)
      expect(Salesforce.leads_enabled?).to eq(true)
      expect(SiteSetting.salesforce_default_contact_id_for_case_sync).to eq("")
      expect(::Salesforce::Case.exists?(live_case.id)).to eq(true)
      expect(::Salesforce::Case.exists?(dead_case.id)).to eq(false)
      expect(::Salesforce::Case.exists?(uidless_case.id)).to eq(false)
      expect(live_case.topic.reload.has_salesforce_case).to eq(true)
      expect(dead_case.topic.reload.has_salesforce_case).to eq(false)
      expect(dead_case_post.reload.custom_fields[::Salesforce::CaseComment::ID_FIELD]).to eq(nil)
    end

    it "removes every dead custom field row while preserving a live row for the same user" do
      contacts_group.add(stale_user)
      [dead_contact_id, live_contact_id, dead_default_contact_id].each do |id|
        UserCustomField.create!(user: stale_user, name: Salesforce::Contact::ID_FIELD, value: id)
      end
      lookup =
        stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
          query: {
            fields: "Id",
            ids: [dead_contact_id, live_contact_id, dead_default_contact_id].join(","),
          },
        ).to_return(body: [nil, { Id: live_contact_id }, nil].to_json)
      candidates = []

      described_class.each_dead_user_link(
        Salesforce::Api.new,
        Salesforce::Contact,
      ) { |user, legacy_id, guided_id| candidates << [user.id, legacy_id, guided_id] }
      expect(candidates).to contain_exactly(
        [stale_user.id, dead_contact_id, nil],
        [stale_user.id, dead_default_contact_id, nil],
      )

      described_class.prune_dead!

      expect(
        stale_user.user_custom_fields.where(name: Salesforce::Contact::ID_FIELD).pluck(:value),
      ).to eq([live_contact_id])
      expect(contacts_group.users.exists?(stale_user.id)).to eq(true)
      expect(lookup).to have_been_requested.twice
    end

    it "prunes guided-only links and fingerprints in the connected account" do
      scope = { provider: "salesforce", account: instance_url, object: "Contact" }
      stale_scope = scope.merge(user_id: stale_user.id)
      live_scope = scope.merge(user_id: linked_user.id)
      other_account_scope = stale_scope.merge(account: "other-account")
      lead_scope = stale_scope.merge(object: "Lead")
      Salesforce::RecordLink.link!(**stale_scope, external_id: dead_contact_id)
      Salesforce::RecordLink.link!(**live_scope, external_id: live_contact_id)
      Salesforce::RecordLink.link!(**other_account_scope, external_id: dead_contact_id)
      Salesforce::RecordLink.mark_converted!(
        **lead_scope,
        external_id: dead_lead_id,
        to_object: "Contact",
        to_id: dead_contact_id,
      )
      configurations = {
        contact: Fabricate(:sync_configuration, object: "Contact", account: instance_url),
        lead: Fabricate(:sync_configuration, object: "Lead", account: instance_url),
        other: Fabricate(:sync_configuration, object: "Contact", account: "other-account"),
      }
      configurations.each_value do |configuration|
        Salesforce::SyncState.store(configuration.id, stale_user.id, fingerprint: "old")
      end
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: "#{live_contact_id},#{dead_contact_id}",
        },
      ).to_return(body: [{ Id: live_contact_id }, nil].to_json)

      expect(described_class.prune_dead![:users]).to eq(1)

      expect(Salesforce::RecordLink.find_by(**stale_scope)).to be_nil
      expect(Salesforce::RecordLink.find_by(**live_scope).external_id).to eq(live_contact_id)
      expect(Salesforce::RecordLink.find_by(**other_account_scope).external_id).to eq(
        dead_contact_id,
      )
      expect(Salesforce::RecordLink.find_by(**lead_scope).converted_to_id).to eq(dead_contact_id)
      fingerprints =
        configurations.transform_values do |configuration|
          Salesforce::SyncState.find_by(
            configuration: configuration,
            user_id: stale_user.id,
          ).fingerprint
        end
      expect(fingerprints).to eq(contact: nil, lead: "old", other: "old")
    end

    it "enumerates linked users without scanning unrelated users" do
      Salesforce::RecordLink.link!(
        provider: "salesforce",
        account: instance_url,
        object: "Contact",
        user_id: stale_user.id,
        external_id: dead_contact_id,
      )
      Salesforce::RecordLink.link!(
        provider: "salesforce",
        account: "other-account",
        object: "Contact",
        user_id: linked_user.id,
        external_id: live_contact_id,
      )
      lookup =
        stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
          query: {
            fields: "Id",
            ids: dead_contact_id,
          },
        ).to_return(body: [nil].to_json)
      candidates = []
      queries = nil

      stub_const(described_class, :BATCH_SIZE, 1) do
        queries =
          track_sql_queries do
            described_class.each_dead_user_link(
              Salesforce::Api.new,
              Salesforce::Contact,
            ) { |user, legacy_id, configured_id| candidates << [user.id, legacy_id, configured_id] }
          end
      end

      expect(candidates).to eq([[stale_user.id, nil, dead_contact_id]])
      expect(lookup).to have_been_requested.once
      expect(
        queries.count do |query|
          query.include?(
            'SELECT "user_custom_fields"."user_id", "user_custom_fields"."value" FROM "user_custom_fields"',
          )
        end,
      ).to eq(1)
    end

    it "preserves guided links replaced while Salesforce is responding" do
      scope = {
        provider: "salesforce",
        account: instance_url,
        object: "Contact",
        user_id: stale_user.id,
      }
      Salesforce::RecordLink.link!(**scope, external_id: dead_contact_id)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact")
        .with(query: { fields: "Id", ids: dead_contact_id })
        .to_return do
          Salesforce::RecordLink.link!(**scope, external_id: live_contact_id)
          { status: 200, body: [nil].to_json }
        end

      expect(described_class.prune_dead![:users]).to eq(0)
      expect(Salesforce::RecordLink.find_by(**scope).external_id).to eq(live_contact_id)
    end

    it "preserves Lead links while cleaning Contacts and Cases when Leads are disabled" do
      SiteSetting.salesforce_leads_enabled = false
      leads_group.add(stale_user)
      stale_user.upsert_custom_fields(
        ::Salesforce::Contact::ID_FIELD => dead_contact_id,
        ::Salesforce::Lead::ID_FIELD => dead_lead_id,
      )
      dead_case = Fabricate(:salesforce_case, uid: dead_case_id)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Contact").with(
        query: {
          fields: "Id",
          ids: dead_contact_id,
        },
      ).to_return(status: 200, body: [nil].to_json)
      stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Case").with(
        query: {
          fields: "Id",
          ids: dead_case_id,
        },
      ).to_return(status: 200, body: [nil].to_json)
      lead_request =
        stub_request(:get, "#{instance_url}services/data/v49.0/composite/sobjects/Lead").to_return(
          status: 400,
          body: %([{"errorCode":"INVALID_TYPE","message":"Lead is unavailable"}]),
        )

      counts = described_class.prune_dead!

      expect(counts).to eq(users: 1, posts: 0, cases: 1, settings: 0)
      expect(stale_user.reload.salesforce_contact_id).to be_nil
      expect(stale_user.salesforce_lead_id).to eq(dead_lead_id)
      expect(::Salesforce::Case.exists?(dead_case.id)).to eq(false)
      expect(lead_request).not_to have_been_requested
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
