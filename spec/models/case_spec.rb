# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::Case do
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  include_context "with salesforce spec helper"

  describe "#delete_and_unlink!" do
    fab!(:salesforce_case) { Fabricate(:salesforce_case, topic: topic) }

    it "deletes the remote case and clears only its local references and tags" do
      SiteSetting.tagging_enabled = true
      SiteSetting.salesforce_automatic_case_sync_tags = "support"
      topic.tags =
        %w[billing support salesforce-case case-new].map { |name| Fabricate(:tag, name: name) }
      topic.upsert_custom_fields(::CaseMixin::HAS_SALESFORCE_CASE => true)
      post.upsert_custom_fields(Salesforce::CaseComment::ID_FIELD => "comment-id")
      other_case = Fabricate(:salesforce_case)
      other_case.topic.upsert_custom_fields(::CaseMixin::HAS_SALESFORCE_CASE => true)
      deletion =
        stub_request(:delete, "#{api_path}/Case/#{salesforce_case.uid}").to_return(status: 204)

      messages =
        MessageBus.track_publish("/topic/#{topic.id}") { salesforce_case.delete_and_unlink! }

      expect(deletion).to have_been_requested.once
      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(false)
      expect(topic.reload.has_salesforce_case).to eq(false)
      expect(post.reload.custom_fields[Salesforce::CaseComment::ID_FIELD]).to eq(nil)
      expect(topic.tags.pluck(:name)).to contain_exactly("billing")
      Jobs::SyncCase.new.execute(topic_id: topic.id)
      expect(Salesforce::Case.exists?(topic_id: topic.id)).to eq(false)
      expect(other_case.topic.reload.has_salesforce_case).to eq(true)
      expect(Salesforce::Case.exists?(other_case.id)).to eq(true)
      expect(messages.map(&:data)).to include({ reload_topic: true })
    end

    it "removes automatic sync tags even when tagging has been disabled" do
      SiteSetting.salesforce_automatic_case_sync_tags = "support"
      topic.tags = [Fabricate(:tag, name: "support")]
      SiteSetting.tagging_enabled = false
      stub_request(:delete, "#{api_path}/Case/#{salesforce_case.uid}").to_return(status: 204)

      salesforce_case.delete_and_unlink!

      expect(topic.reload.tags).to be_empty
    end

    it "retains links and tags when remote deletion fails" do
      SiteSetting.tagging_enabled = true
      topic.tags = [Fabricate(:tag, name: "salesforce-case")]
      topic.upsert_custom_fields(::CaseMixin::HAS_SALESFORCE_CASE => true)
      post.upsert_custom_fields(Salesforce::CaseComment::ID_FIELD => "comment-id")
      stub_request(:delete, "#{api_path}/Case/#{salesforce_case.uid}").to_return(
        status: 403,
        body: "Denied",
      )

      expect { salesforce_case.delete_and_unlink! }.to raise_error(Salesforce::InvalidApiResponse)

      expect(Salesforce::Case.exists?(salesforce_case.id)).to eq(true)
      expect(topic.reload.has_salesforce_case).to eq(true)
      expect(post.reload.custom_fields[Salesforce::CaseComment::ID_FIELD]).to eq("comment-id")
      expect(topic.tags.pluck(:name)).to contain_exactly("salesforce-case")
    end
  end

  describe ".sync!" do
    before do
      Salesforce.seed_groups!

      stub_request(:get, "#{api_path}/Case/234567").to_return(
        status: 200,
        body: %({"CaseNumber":"345678","Status":"New"}),
      )
    end

    def stub_new_case_request(expected_req_body = {}, expected_resp_body = {})
      default_req_body = {
        ContactId: nil,
        Subject: "#{topic.title}",
        Description: "#{post.full_url}\n\n#{post.raw}",
        Origin: "Web",
      }

      default_resp_body = { id: "234567" }

      stub_request(:post, "#{api_path}/Case").with(
        body: default_req_body.merge(expected_req_body).to_json,
      ).to_return(status: 200, body: default_resp_body.merge(expected_resp_body).to_json)
    end

    context "with case tagging enabled" do
      before do
        SiteSetting.salesforce_skip_contact_creation_on_case_sync = true
        SiteSetting.tagging_enabled = true
        SiteSetting.salesforce_case_tag_name = "salesforce-case"
        SiteSetting.salesforce_case_status_tag_enabled = true
        SiteSetting.salesforce_case_status_tag_prefix = "case"
        topic.tags = [Fabricate(:tag, name: "billing"), Fabricate(:tag, name: "urgent")]

        stub_new_case_request
      end

      it "preserves existing tags when a case is initially synced" do
        ::Salesforce::Case.sync!(topic)

        expect(topic.reload.tags.pluck(:name)).to contain_exactly(
          "billing",
          "urgent",
          "salesforce-case",
          "case-new",
        )
      end

      it "replaces the previous Salesforce case status tag on later syncs" do
        ::Salesforce::Case.sync!(topic)

        stub_request(:get, "#{api_path}/Case/234567").to_return(
          status: 200,
          body: %({"CaseNumber":"345678","Status":"Closed"}),
        )

        ::Salesforce::Case.sync!(topic)

        expect(topic.reload.tags.pluck(:name)).to contain_exactly(
          "billing",
          "urgent",
          "salesforce-case",
          "case-closed",
        )
      end

      it "preserves existing tags when the topic is at the tag limit" do
        topic.tags += %w[customer support priority].map { |name| Fabricate(:tag, name: name) }

        ::Salesforce::Case.sync!(topic)

        expect(topic.reload.tags.pluck(:name)).to contain_exactly(
          "billing",
          "urgent",
          "customer",
          "support",
          "priority",
        )
      end
    end

    shared_examples "existing contact" do
      it "uses the existing contact" do
        topic.user.salesforce_contact_id = "123456"
        topic.user.save_custom_fields

        stub_request(:post, "#{api_path}/Case").with(
          body:
            %({"ContactId":"123456","Subject":"#{topic.title}","Description":"#{post.full_url}\\n\\n#{post.raw}","Origin":"Web"}),
        ).to_return(status: 200, body: %({"id":"234567"}), headers: {})

        expect do ::Salesforce::Case.sync!(topic) end.to change { ::Salesforce::Case.count }.by(1)

        expect(topic.user.salesforce_contact_id).to eq("123456")
      end
    end

    context "when salesforce_skip_contact_creation_on_case_sync is true" do
      before { SiteSetting.salesforce_skip_contact_creation_on_case_sync = true }

      it "does not create contact if none exist" do
        stub_request(:post, "#{api_path}/Case").with(
          body:
            %({"ContactId":null,"Subject":"#{topic.title}","Description":"#{post.full_url}\\n\\n#{post.raw}","Origin":"Web"}),
        ).to_return(status: 200, body: %({"id":"234567"}), headers: {})

        expect do ::Salesforce::Case.sync!(topic) end.to change { ::Salesforce::Case.count }.by(1)

        expect(topic.user.salesforce_contact_id).to be_nil
      end

      it "uses salesforce_default_contact_id_for_case_sync for ContactId if present" do
        SiteSetting.salesforce_default_contact_id_for_case_sync = "4546566"

        stub_request(:post, "#{api_path}/Case").with(
          body:
            %({"ContactId":"4546566","Subject":"#{topic.title}","Description":"#{post.full_url}\\n\\n#{post.raw}","Origin":"Web"}),
        ).to_return(status: 200, body: %({"id":"234567"}), headers: {})

        expect do ::Salesforce::Case.sync!(topic) end.to change { ::Salesforce::Case.count }.by(1)
      end

      include_examples "existing contact"
    end

    context "when salesforce_skip_contact_creation_on_case_sync is false" do
      before do
        SiteSetting.salesforce_skip_contact_creation_on_case_sync = false

        stub_salesforce_person_lookup("Contact", topic.user.email)

        stub_request(:post, "#{api_path}/Contact").with(
          body: topic.user.salesforce_contact_payload.to_json,
        ).to_return(status: 200, body: %({"id":"123456"}), headers: {})

        stub_request(:post, "#{api_path}/Case").with(
          body:
            %({"ContactId":"123456","Subject":"#{topic.title}","Description":"#{post.full_url}\\n\\n#{post.raw}","Origin":"Web"}),
        ).to_return(status: 200, body: %({"id":"234567"}), headers: {})
      end

      it "creates a new contact if none exist" do
        expect(topic.user.salesforce_contact_id).to be_nil

        expect do ::Salesforce::Case.sync!(topic) end.to change { ::Salesforce::Case.count }.by(1)

        expect(topic.user.salesforce_contact_id).to eq("123456")
      end

      it "uses an existing salesforce contact when one matches the topic user email" do
        stub_salesforce_person_lookup("Contact", topic.user.email, id: "existing_contact_id")

        stub_request(:post, "#{api_path}/Case").with(
          body:
            %({"ContactId":"existing_contact_id","Subject":"#{topic.title}","Description":"#{post.full_url}\\n\\n#{post.raw}","Origin":"Web"}),
        ).to_return(status: 200, body: %({"id":"234567"}), headers: {})

        expect do ::Salesforce::Case.sync!(topic) end.to change { ::Salesforce::Case.count }.by(1)

        expect(topic.user.salesforce_contact_id).to eq("existing_contact_id")
        expect(Salesforce.contacts_group.users.exists?(topic.user.id)).to eq(true)
        expect(a_request(:post, "#{api_path}/Contact")).not_to have_been_made
      end

      include_examples "existing contact"
    end

    context "with salesforce_case_origin" do
      before { SiteSetting.salesforce_skip_contact_creation_on_case_sync = true }

      it "sends the configured origin" do
        SiteSetting.salesforce_case_origin = "Community"
        create_case = stub_new_case_request({ Origin: "Community" })

        ::Salesforce::Case.sync!(topic)

        expect(create_case).to have_been_requested
      end

      it "omits the origin when it is blank" do
        SiteSetting.salesforce_case_origin = ""

        create_case =
          stub_request(:post, "#{api_path}/Case")
            .with { |request| JSON.parse(request.body).exclude?("Origin") }
            .to_return(status: 200, body: %({"id":"234567"}))

        ::Salesforce::Case.sync!(topic)

        expect(create_case).to have_been_requested
      end
    end

    context "with custom field" do
      let(:plugin_instance) { Plugin::Instance.new }
      let(:modifier_block) do
        Proc.new { |default_payload, _| default_payload.merge(CustomField__c: "Custom Value") }
      end

      before do
        SiteSetting.salesforce_skip_contact_creation_on_case_sync = true

        plugin_instance.register_modifier(:salesforce_case_payload, &modifier_block)

        stub_new_case_request({ CustomField__c: "Custom Value" })
      end

      after do
        DiscoursePluginRegistry.unregister_modifier(
          plugin_instance,
          :salesforce_case_payload,
          &modifier_block
        )
      end

      it "syncs with modified payload" do
        expect do ::Salesforce::Case.sync!(topic) end.to change { ::Salesforce::Case.count }.by(1)
      end
    end
  end
end
