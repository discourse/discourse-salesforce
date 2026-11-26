# frozen_string_literal: true

module PageObjects
  module Pages
    class SalesforceConfigurations < PageObjects::Pages::Base
      def visit
        page.visit("/admin/plugins/discourse-salesforce/configurations")
        self
      end

      def start_pull
        find("[data-test-pull-crm]").click
        self
      end

      def has_pull_disabled?
        has_css?("[data-test-pull-crm][disabled]")
      end

      def has_pull_object?(label)
        has_css?('[data-name="target"] .form-kit__control-menu-trigger', text: label)
      end

      def choose_pull_target(value)
        PageObjects::Components::FormKitField.new('[data-name="target"]').select(value)
        self
      end

      def add_property(name)
        find("[data-test-add-pull-field]").click
        index = all(".salesforce-sync-configuration__mapping-row").size - 1
        choose_menu_item("[data-name=\"pull_mappings.#{index}.source\"]", name)
        self
      end

      def choose_destination(property, value)
        choose_menu_item("[data-test-mapping=\"#{property}\"] [data-name$=\".destination\"]", value)
        self
      end

      def choose_policy(property, value)
        choose_menu_item("[data-test-mapping=\"#{property}\"] [data-name$=\".policy\"]", value)
        self
      end

      def has_property?(property, destination: nil)
        row = "[data-test-mapping=\"#{property}\"]"
        destination ? has_css?(row, text: destination) : has_css?(row)
      end

      def has_mapping_error?(index, text)
        has_css?("[data-name=\"pull_mappings.#{index}.destination\"] .form-kit__errors", text: text)
      end

      def choose_schedule(value)
        PageObjects::Components::FormKitField.new('[data-name="schedule"]').select(value)
        self
      end

      def has_schedule?(label)
        has_css?('[data-name="schedule"] .form-kit__control-menu-trigger', text: label)
      end

      def save
        find("[data-test-save]").click
        self
      end

      def has_configuration?(name, type:, scope:)
        has_css?("[data-test-configuration]", text: name) &&
          has_css?("[data-test-configuration]", text: type) &&
          has_css?("[data-test-configuration] [data-test-configuration-scope]", text: scope)
      end

      def choose_menu_item(field, value)
        find("#{field} .form-kit__control-menu-trigger").click
        find(".form-kit__control-menu-item[data-value=\"#{value}\"] button").click
      end

      def open_configuration(name)
        find("[data-test-configuration]", text: name).find("[data-test-configure]").click
        self
      end
    end
  end
end
