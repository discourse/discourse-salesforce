# frozen_string_literal: true

RSpec.describe Salesforce::CaseUnlinkAllowedGroupsSiteSetting do
  describe "site setting validation" do
    it "accepts only admins and moderators, separately or together, or an empty list" do
      %i[
        salesforce_case_unlink_allowed_groups
        salesforce_contact_unlink_allowed_groups
      ].each do |setting|
        ["", "admins", "moderators", "admins|moderators"].each do |value|
          SiteSetting.public_send("#{setting}=", value)
          expect(SiteSetting.public_send(setting)).to eq(value)
        end

        ["everyone", Fabricate(:group).id.to_s, "admins|trust_level_4"].each do |value|
          expect { SiteSetting.public_send("#{setting}=", value) }.to raise_error(
            Discourse::InvalidParameters,
          )
        end
      end
    end
  end
end
