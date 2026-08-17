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

    context "with duplicate sync attempts" do
      before { SiteSetting.salesforce_skip_contact_creation_on_case_sync = true }

      it "re-syncs the existing case instead of creating a second one" do
        stub_new_case_request

        ::Salesforce::Case.sync!(topic)

        expect { ::Salesforce::Case.sync!(topic) }.not_to change { ::Salesforce::Case.count }
        expect(a_request(:post, "#{api_path}/Case")).to have_been_made.once
      end

      it "converges on the case a concurrent sync created first" do
        existing_case = Fabricate(:salesforce_case, topic: topic, uid: "234567")
        # The loser of the race checked for a case before the winner's insert
        # became visible.
        ::Salesforce::Case.stubs(:find_or_initialize_by).returns(
          ::Salesforce::Case.new(topic_id: topic.id),
        )
        stub_new_case_request

        result = ::Salesforce::Case.sync!(topic)

        expect(result.id).to eq(existing_case.id)
        expect(::Salesforce::Case.where(topic_id: topic.id).count).to eq(1)
        expect(result.reload.number).to eq("345678")
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
