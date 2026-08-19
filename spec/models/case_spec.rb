# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::Case do
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  include_context "with salesforce spec helper"

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

    context "when an external ID field is configured" do
      before do
        SiteSetting.salesforce_skip_contact_creation_on_case_sync = true
        SiteSetting.salesforce_case_external_id_field = "Discourse_Topic_Case_Id__c"
      end

      def upsert_url
        external_id = CGI.escape("#{Discourse.current_hostname}:#{topic.id}")
        "#{api_path}/Case/Discourse_Topic_Case_Id__c/#{external_id}"
      end

      def base_payload_json
        {
          ContactId: nil,
          Subject: topic.title,
          Description: "#{post.full_url}\n\n#{post.raw}",
          Origin: "Web",
        }.to_json
      end

      it "creates the case with an idempotent upsert" do
        stub_request(:patch, upsert_url).with(body: base_payload_json).to_return(
          status: 201,
          body: %({"id":"234567","success":true,"errors":[],"created":true}),
        )

        expect { ::Salesforce::Case.sync!(topic) }.to change { ::Salesforce::Case.count }.by(1)

        expect(::Salesforce::Case.find_by(topic_id: topic.id).uid).to eq("234567")
        expect(a_request(:post, "#{api_path}/Case")).not_to have_been_made
      end

      it "links and refreshes an existing case returned by the upsert" do
        stub_request(:patch, upsert_url).with(body: base_payload_json).to_return(
          status: 200,
          body: %({"id":"234567","success":true,"errors":[],"created":false}),
        )

        expect { ::Salesforce::Case.sync!(topic) }.to change { ::Salesforce::Case.count }.by(1)

        expect(::Salesforce::Case.find_by(topic_id: topic.id).uid).to eq("234567")
        expect(a_request(:post, "#{api_path}/Case")).not_to have_been_made
        expect(a_request(:patch, upsert_url)).to have_been_made.once
      end

      it "keeps the external ID out of the request body even when a modifier adds it" do
        plugin_instance = Plugin::Instance.new
        modifier = Proc.new { |fields, _| fields.merge(Discourse_Topic_Case_Id__c: "hijacked") }
        plugin_instance.register_modifier(:salesforce_case_payload, &modifier)

        stub_request(:patch, upsert_url).with(body: base_payload_json).to_return(
          status: 201,
          body: %({"id":"234567","success":true,"errors":[],"created":true}),
        )

        expect { ::Salesforce::Case.sync!(topic) }.to change { ::Salesforce::Case.count }.by(1)
      ensure
        DiscoursePluginRegistry.unregister_modifier(
          plugin_instance,
          :salesforce_case_payload,
          &modifier
        )
      end

      it "rejects an invalid field name" do
        expect { SiteSetting.salesforce_case_external_id_field = "bad name" }.to raise_error(
          Discourse::InvalidParameters,
        )
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
