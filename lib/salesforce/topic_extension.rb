# frozen_string_literal: true

module Salesforce
  module TopicExtension
    extend ActiveSupport::Concern

    def has_salesforce_case
      custom_fields["has_salesforce_case"] ? true : false
    end

    def salesforce_case
      return unless has_salesforce_case
      ::Salesforce::Case.find_by(topic_id: id)
    end
  end
end
