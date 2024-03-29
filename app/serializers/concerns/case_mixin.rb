# frozen_string_literal: true

module CaseMixin
  HAS_SALESFORCE_CASE = "has_salesforce_case"

  def self.included(klass)
    klass.attributes :has_salesforce_case
  end

  def has_salesforce_case
    object.has_salesforce_case
  end

  def include_has_salesforce_case?
    SiteSetting.salesforce_enabled && scope.is_staff?
  end
end
