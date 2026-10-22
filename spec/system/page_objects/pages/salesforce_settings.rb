# frozen_string_literal: true

module PageObjects
  module Pages
    class SalesforceSettings < AdminSiteSettings
      def unlink_groups
        PageObjects::Components::SelectKit.new(unlink_groups_selector)
      end

      def has_two_unlink_group_options?
        has_css?("#{unlink_groups_selector}.is-expanded .select-kit-row", count: 2)
      end

      private

      def unlink_groups_selector
        "#{setting_row_selector("salesforce_case_unlink_allowed_groups")} .list-setting"
      end
    end
  end
end
