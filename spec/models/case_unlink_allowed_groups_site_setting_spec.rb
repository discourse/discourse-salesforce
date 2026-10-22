# frozen_string_literal: true

RSpec.describe Salesforce::CaseUnlinkAllowedGroupsSiteSetting do
  describe "site setting validation" do
    it "accepts only admins and moderators, separately or together, or an empty list" do
      ["", "admins", "moderators", "admins|moderators"].each do |value|
        SiteSetting.salesforce_case_unlink_allowed_groups = value
        expect(SiteSetting.salesforce_case_unlink_allowed_groups).to eq(value)
      end

      ["everyone", Fabricate(:group).id.to_s, "admins|trust_level_4"].each do |value|
        expect { SiteSetting.salesforce_case_unlink_allowed_groups = value }.to raise_error(
          Discourse::InvalidParameters,
        )
      end
    end
  end
end
