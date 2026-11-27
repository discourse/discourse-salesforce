# frozen_string_literal: true

require_relative "salesforce_configurations"

module PageObjects
  module Pages
    class CrmSegments < PageObjects::Pages::SalesforceConfigurations
      def define_segment
        find("[data-test-define-segment]").click
        self
      end

      def has_define_disabled?
        has_css?("[data-test-define-segment][disabled]")
      end

      def has_configuration?(configuration)
        form.field("configuration_id").has_value?(configuration.id.to_s)
      end

      def choose_property(index, property_id)
        form.collection_field("conditions", index, "property").select(property_id)
        self
      end

      def choose_operator(index, operator)
        form.collection_field("conditions", index, "operator").select(operator)
        self
      end

      def fill_value(index, value)
        form.collection_field("conditions", index, "value").fill_in(value)
        self
      end

      def add_condition
        find("[data-test-add-condition]").click
        self
      end

      def choose_match(value)
        form.field("match").select(value)
        self
      end

      def has_match?(value)
        form.field("match").has_value?(value)
      end

      def choose_group(group)
        find('[data-name="group_id"] .d-multi-select-trigger__expand-btn').click
        find(".d-multi-select__search-input").fill_in(with: group.name)
        find(".d-multi-select__result", text: group.name).click
        find(".crm-segment-editor__heading").click
        self
      end

      def has_group?(group)
        has_css?('[data-name="group_id"] .d-multi-select-trigger__selected-item', text: group.name)
      end

      def enable_removal
        form.field("remove_unmatched").check
        self
      end

      def has_removal_enabled?
        form.field("remove_unmatched").checked?
      end

      def has_preview?(text)
        has_css?("[data-test-preview]", text: text)
      end

      def enable_flair
        form.field("flair_enabled").check
        self
      end

      def has_flair_enabled?
        form.field("flair_enabled").checked?
      end

      def choose_flair_text(property_id)
        form.field("flair_text_property").select(property_id)
        self
      end

      def has_flair_text?(property_id)
        form.field("flair_text_property").has_value?(property_id)
      end

      def choose_flair_property(label)
        pick_from_multi_select("flair_properties", label)
      end

      def choose_flair_group(group)
        pick_from_multi_select("flair_group_ids", group.name)
      end

      def has_flair_group?(group)
        has_css?(
          '[data-name="flair_group_ids"] .d-multi-select-trigger__selected-item',
          text: group.name,
        )
      end

      def has_flair_preview?(text)
        has_css?("[data-test-flair-preview] .crm-flair__text", exact_text: text)
      end

      def has_condition_value?(index, value)
        form.collection_field("conditions", index, "value").has_value?(value)
      end

      def save
        find("[data-test-save]").click
        self
      end

      def has_segment?(name, configuration: nil, group: nil, status: nil, flair: nil)
        row = "[data-test-segment]"
        has_css?(row, text: name) &&
          (
            configuration.nil? ||
              has_css?("#{row} [data-test-segment-configuration]", text: configuration.name)
          ) && (group.nil? || has_css?(row, text: group.name)) &&
          (status.nil? || has_css?("#{row} [data-test-segment-status='#{status}']")) &&
          (flair.nil? || has_css?("#{row} [data-test-segment-flair]", text: flair))
      end

      def has_no_segment?(name)
        has_no_css?("[data-test-segment]", text: name)
      end

      def has_member_count?(name, count)
        find("[data-test-segment]", text: name).has_css?(
          "[data-test-segment-members]",
          exact_text: count.to_s,
        )
      end

      def open_segment(name)
        find("[data-test-segment]", text: name).find("[data-test-configure-segment]").click
        self
      end

      def delete_segment(name)
        find("[data-test-segment]", text: name).find("[data-test-delete-segment]").click
        PageObjects::Components::Dialog.new.click_danger
        self
      end

      private

      def pick_from_multi_select(field, text)
        find("[data-name=\"#{field}\"] .d-multi-select-trigger__expand-btn").click
        find(".d-multi-select__search-input").fill_in(with: text)
        find(".d-multi-select__result", text: text).click
        find(".crm-segment-editor__heading").click
        self
      end

      def form
        PageObjects::Components::FormKit.new(".crm-segment-editor__form")
      end
    end
  end
end
