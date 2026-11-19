# frozen_string_literal: true

require_relative "../spec_helper"
require Rails.root.join(
          "plugins/discourse-salesforce/db/migrate/20261117113418_add_object_to_hubspot_mappings.rb",
        )

RSpec.describe AddObjectToHubspotMappings do
  include_context "with hubspot spec helper"

  before do
    @original_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  after { ActiveRecord::Migration.verbose = @original_verbose }

  it "marks every existing HubSpot mapping as a contact property, in order" do
    pull =
      Fabricate(
        :hubspot_sync_configuration,
        mappings: [{ "id" => 1, "source" => "jobtitle" }, { "id" => 2, "source" => "city" }],
      )
    empty = Fabricate(:hubspot_sync_configuration, account: "99999", mappings: [])
    send = Fabricate(:sync_configuration, groups: [Fabricate(:group)])
    original_send_mappings = send.mappings

    described_class.new.up

    expect(pull.reload.mappings).to eq(
      [
        { "id" => 1, "object" => "contact", "source" => "jobtitle" },
        { "id" => 2, "object" => "contact", "source" => "city" },
      ],
    )
    expect(empty.reload.mappings).to eq([])
    expect(send.reload.mappings).to eq(original_send_mappings)
  end
end
