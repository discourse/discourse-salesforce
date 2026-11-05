# frozen_string_literal: true

module Salesforce
  class GuidedSyncConfigurationGroup < ActiveRecord::Base
    self.table_name = "crm_sync_configuration_groups"

    belongs_to :configuration, class_name: "Salesforce::GuidedSyncConfiguration"
    belongs_to :group
  end
end
