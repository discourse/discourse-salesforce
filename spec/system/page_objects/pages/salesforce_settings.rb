# frozen_string_literal: true

module PageObjects
  module Pages
    class SalesforceSettings < AdminSiteSettings
      def unlink_groups(record_type)
        PageObjects::Components::SelectKit.new(unlink_groups_selector(record_type))
      end

      def has_two_unlink_group_options?(record_type)
        has_css?("#{unlink_groups_selector(record_type)}.is-expanded .select-kit-row", count: 2)
      end

      private

      def unlink_groups_selector(record_type)
        "#{setting_row_selector("salesforce_#{record_type}_unlink_allowed_groups")} .list-setting"
      end
    end
  end
end
