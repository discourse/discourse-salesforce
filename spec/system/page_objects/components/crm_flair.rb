# frozen_string_literal: true

module PageObjects
  module Components
    class CrmFlair < PageObjects::Components::Base
      TOOLTIP = ".fk-d-tooltip__content[data-identifier='crm-flair']"

      def initialize(post)
        @post = post
      end

      def has_text?(text)
        has_css?("#{selector} .crm-flair__text", exact_text: text)
      end

      def has_no_flair?
        has_no_css?(selector)
      end

      def hover
        find("#{selector} .crm-flair__chip").hover
        self
      end

      def has_property?(label, value)
        has_css?("#{TOOLTIP} .crm-flair__row", text: /#{Regexp.escape(label)}/i) &&
          has_css?("#{TOOLTIP} .crm-flair__row .crm-flair__value", exact_text: value)
      end

      def has_crm_link?(text, href)
        has_css?("#{TOOLTIP} .crm-flair__link[href='#{href}']", text: text)
      end

      private

      def selector
        "#post_#{@post.post_number} [data-test-crm-flair]"
      end
    end
  end
end
