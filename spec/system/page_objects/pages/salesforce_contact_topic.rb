# frozen_string_literal: true

module PageObjects
  module Pages
    class SalesforceContactTopic < Topic
      def open_contact_menu(post)
        click_post_action_button(post, :show_more)
        expand_post_admin_actions(post)
      end

      def has_contact_unlink_action?
        has_no_css?("[data-identifier='admin-post-menu'] .create-contact") &&
          has_css?("[data-identifier='admin-post-menu'] .unlink-salesforce-contact")
      end

      def has_contact_creation_action?
        has_css?("[data-identifier='admin-post-menu'] .create-contact") &&
          has_no_contact_unlink_action?
      end

      def unlink_contact
        find("[data-identifier='admin-post-menu'] .unlink-salesforce-contact").click
      end

      def has_contact_for?(post)
        within_post(post) { has_css?(".salesforce-contact") }
      end

      def has_no_contact_for?(post)
        within_post(post) { has_no_css?(".salesforce-contact") }
      end

      def has_no_contact_unlink_action?
        has_no_css?("[data-identifier='admin-post-menu'] .unlink-salesforce-contact")
      end
    end
  end
end
