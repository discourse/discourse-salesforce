# frozen_string_literal: true

require_relative "../../db/migrate/20240904035546_update_salesforce_oauth_provider_uid.rb"

RSpec.describe "UpdateSalesforceOauthProviderUid" do
  fab!(:user1) { Fabricate(:user) }
  fab!(:user2) { Fabricate(:user) }

  it "properly updates the uid" do
    salesforce1 =
      UserAssociatedAccount.create(
        user_id: user1.id,
        provider_uid: "https://login.salesforce.com/id/00D5Y000001cLNoUAM/0055Y00000F77E3QAJ",
        provider_name: "salesforce",
      )
    salesforce2 =
      UserAssociatedAccount.create(
        user_id: user2.id,
        provider_uid: "abcdxyz",
        provider_name: "salesforce",
      )
    not_salesforce =
      UserAssociatedAccount.create(
        user_id: user1.id,
        provider_uid: "https://login.salesforce.com/id/00D5Y000001cLNoUAM/0055Y00000F77E3QAJ",
        provider_name: "not_salesforce",
      )

    UpdateSalesforceOauthProviderUid.new.up

    expect(salesforce1.reload.provider_uid).to eq("0055Y00000F77E3QAJ")
    expect(salesforce2.reload.provider_uid).to eq("abcdxyz")
    expect(not_salesforce.reload.provider_uid).to eq(
      "https://login.salesforce.com/id/00D5Y000001cLNoUAM/0055Y00000F77E3QAJ",
    )
  end
end
