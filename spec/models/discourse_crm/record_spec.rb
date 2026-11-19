# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe DiscourseCrm::Record do
  include_context "with hubspot spec helper"

  it "resolves a contact's company through the shared provider and account" do
    company =
      Fabricate(:crm_record, object: "company", external_id: "900", data: { "name" => "Acme" })
    Fabricate(:crm_record, object: "company", account: "99999", external_id: "901")
    linked = Fabricate(:crm_record, external_id: "501", company_external_id: "900")
    other_portal = Fabricate(:crm_record, external_id: "502", company_external_id: "901")
    unlinked = Fabricate(:crm_record, external_id: "503")

    expect(linked.company).to eq(company)
    expect(other_portal.company).to be_nil
    expect(unlinked.company).to be_nil
  end
end
