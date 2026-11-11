# frozen_string_literal: true

module PageObjects
  module Pages
    class SalesforceConfigurations < PageObjects::Pages::Base
      def visit
        page.visit("/admin/plugins/discourse-salesforce/configurations")
        self
      end

      def start_hubspot_pull
        find("[data-test-sync-contacts]").click
        self
      end

      def has_hubspot_pull_disabled?
        has_css?("[data-test-sync-contacts][disabled]")
      end

      def select_property(label)
        find('[data-name="mappings"] .d-multi-select-trigger__expand-btn').click
        find(".d-multi-select__search-input").fill_in(with: label)
        find(".d-multi-select__result", text: label).click
        find(".hubspot-sync-configuration__heading").click
        self
      end

      def has_selected_properties?(*labels)
        labels.all? do |label|
          has_css?('[data-name="mappings"] .d-multi-select-trigger__selected-item', text: label)
        end
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

      def open_configuration(name)
        find("[data-test-configuration]", text: name).find("[data-test-configure]").click
        self
      end
    end
  end
end
