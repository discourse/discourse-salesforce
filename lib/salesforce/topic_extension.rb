# frozen_string_literal: true

module Salesforce
  module TopicExtension
    extend ActiveSupport::Concern

    def has_salesforce_case
      return @has_salesforce_case if defined?(@has_salesforce_case)

      field = CaseMixin::HAS_SALESFORCE_CASE
      value =
        if custom_field_preloaded?(field)
          custom_fields[field]
        elsif custom_fields_preloaded?
          _custom_fields.where(name: field).pick(:value)
        else
          custom_fields[field]
        end

      @has_salesforce_case = ActiveModel::Type::Boolean.new.cast(value)
    end

    def salesforce_case
      return unless has_salesforce_case
      ::Salesforce::Case.find_by(topic_id: id)
    end
  end
end
