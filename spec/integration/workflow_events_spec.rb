# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Salesforce workflow events" do
  include_context "with salesforce spec helper"

  fab!(:admin)
  fab!(:user) { Fabricate(:verified_user, name: "Alex Morgan") }
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:first_post) { Fabricate(:post, topic: topic) }

  def track(event_name, &block)
    DiscourseEvent.track_events(event_name, &block).pluck(:params)
  end

  before { Salesforce.seed_groups! }

  describe ":salesforce_case_created" do
    before do
      SiteSetting.salesforce_skip_contact_creation_on_case_sync = true
      stub_request(:post, "#{api_path}/Case").to_return(status: 200, body: { id: "234567" }.to_json)
      stub_request(:get, "#{api_path}/Case/234567").to_return(
        status: 200,
        body: { CaseNumber: "345678", Status: "New" }.to_json,
      )
    end

    it "fires once for a new case with the synced number and the acting user" do
      events = track(:salesforce_case_created) { Salesforce::Case.sync!(topic, acting_user: admin) }

      salesforce_case = Salesforce::Case.find_by(topic_id: topic.id)
      expect(events).to eq([[salesforce_case, { acting_user: admin }]])
      expect(salesforce_case).to have_attributes(uid: "234567", number: "345678", status: "New")
    end

    it "still fires once when reading the new case back fails, and not again on retry" do
      stub_request(:get, "#{api_path}/Case/234567")
        .to_return(status: 503, body: "")
        .then
        .to_return(status: 200, body: { CaseNumber: "345678", Status: "New" }.to_json)

      events =
        track(:salesforce_case_created) do
          expect { Salesforce::Case.sync!(topic) }.to raise_error(Salesforce::InvalidApiResponse)
        end

      salesforce_case = Salesforce::Case.find_by(topic_id: topic.id)
      expect(events).to eq([[salesforce_case, { acting_user: nil }]])
      expect(salesforce_case).to have_attributes(uid: "234567", number: nil, status: nil)

      retried = track(:salesforce_case_created) { Salesforce::Case.sync!(topic) }

      expect(retried).to be_empty
      expect(salesforce_case.reload.number).to eq("345678")
    end

    it "does not fire when an existing case is synced again" do
      Salesforce::Case.sync!(topic)

      events = track(:salesforce_case_created) { Salesforce::Case.sync!(topic, acting_user: admin) }

      expect(events).to be_empty
    end
  end

  describe ":salesforce_person_linked" do
    let(:lead_fields) { %w[LastName Company] }

    def linked_events(&block)
      track(:salesforce_person_linked, &block)
    end

    def link_event(object, id, created:, acting_user: nil)
      [user, object, id, { created:, email_verified: true, acting_user: }]
    end

    context "when an admin creates a record" do
      before { sign_in(admin) }

      it "reports a created Contact with the admin as the actor" do
        stub_salesforce_person_lookup("Contact", user.email)
        stub_request(:post, "#{api_path}/Contact").to_return(
          status: 200,
          body: { id: "contact123" }.to_json,
        )

        events =
          linked_events do
            post "/salesforce/persons/create.json", params: { user_id: user.id, type: "contact" }
          end

        expect(response.status).to eq(200)
        expect(events).to eq(
          [link_event("Contact", "contact123", created: true, acting_user: admin)],
        )
      end

      it "reports an existing Contact as linked rather than created" do
        stub_salesforce_person_lookup("Contact", user.email, id: "contact123")

        events =
          linked_events do
            post "/salesforce/persons/create.json", params: { user_id: user.id, type: "contact" }
          end

        expect(events).to eq(
          [link_event("Contact", "contact123", created: false, acting_user: admin)],
        )
      end
    end

    it "reports the Contact created for a new case with the acting user" do
      SiteSetting.salesforce_skip_contact_creation_on_case_sync = false
      stub_salesforce_person_lookup("Contact", user.email)
      stub_request(:post, "#{api_path}/Contact").to_return(
        status: 200,
        body: { id: "contact123" }.to_json,
      )
      stub_request(:post, "#{api_path}/Case").to_return(status: 200, body: { id: "234567" }.to_json)
      stub_request(:get, "#{api_path}/Case/234567").to_return(
        status: 200,
        body: { CaseNumber: "345678", Status: "New" }.to_json,
      )

      events = linked_events { Salesforce::Case.sync!(topic, acting_user: admin) }

      expect(events).to eq([link_event("Contact", "contact123", created: true, acting_user: admin)])
    end

    it "reports a Lead linked by the signup job" do
      stub_salesforce_person_lookup("Contact", user.email)
      stub_salesforce_person_lookup("Lead", user.email, id: "lead123")

      events = linked_events { Jobs::SyncSalesforceUser.new.execute(user_id: user.id) }

      expect(events).to eq([link_event("Lead", "lead123", created: false)])
    end

    it "does not report a link that an overlapping sync already stored" do
      stale_user = User.find(user.id)
      stale_user.custom_fields
      stub_salesforce_person_lookup("Contact", user.email, id: "contact123")

      events =
        linked_events do
          Salesforce::Contact.create!(user)
          Salesforce::Contact.sync(stale_user)
        end

      expect(events).to eq([link_event("Contact", "contact123", created: false)])
    end

    it "reports the Contact linked when a converted Lead is reconciled during creation" do
      stub_salesforce_person_lookup("Lead", user.email)
      stub_salesforce_converted_lead_lookup(
        user.email,
        records: [{ Id: "converted-lead", IsConverted: true, ConvertedContactId: "contact1" }],
      )

      events = linked_events { Salesforce::Lead.create!(user, acting_user: admin) }

      expect(events).to eq([link_event("Contact", "contact1", created: false, acting_user: admin)])
    end

    context "with guided sync" do
      fab!(:group)
      let!(:configuration) do
        Fabricate(:sync_configuration, groups: [group], object: "Lead", account: instance_url)
      end
      let(:fields) do
        %w[Email LastName Company].map do |name|
          { name: name, type: "string", createable: true, updateable: true }
        end
      end

      before do
        SiteSetting.enable_guided_sync_configuration = true
        group.add(user)
        stub_request(:get, "#{api_path}/Lead/describe").to_return(body: { fields: fields }.to_json)
        stub_salesforce_converted_lead_lookup(user.email)
      end

      def run_sync
        Jobs::SyncSalesforceUser.new.execute(
          configuration_id: configuration.id,
          user_id: user.id,
          reason: "backfill",
        )
      end

      it "reports a created Lead once and stays quiet on later syncs" do
        stub_salesforce_person_lookup("Lead", user.email, fields: lead_fields)
        stub_request(:post, "#{api_path}/Lead").to_return(
          status: 201,
          body: { id: "lead123" }.to_json,
        )

        events = linked_events { run_sync }

        expect(events).to eq([link_event("Lead", "lead123", created: true)])

        stub_request(:get, "#{api_path}/Lead/lead123").to_return(
          body: { Id: "lead123", LastName: "Morgan", Company: "None" }.to_json,
        )
        expect(linked_events { run_sync }).to be_empty
      end

      it "reports an existing Lead as linked" do
        record = { Id: "lead123", LastName: "Morgan", Company: "None" }
        stub_salesforce_person_lookup("Lead", user.email, fields: lead_fields, record: record)

        events = linked_events { run_sync }

        expect(events).to eq([link_event("Lead", "lead123", created: false)])
      end

      it "reports the Contact linked when a converted Lead is reconciled" do
        stub_salesforce_person_lookup("Lead", user.email, fields: lead_fields)
        stub_salesforce_converted_lead_lookup(
          user.email,
          records: [{ Id: "converted-lead", IsConverted: true, ConvertedContactId: "contact1" }],
        )

        events = linked_events { run_sync }

        expect(events).to eq([link_event("Contact", "contact1", created: false)])
      end
    end
  end
end
