# frozen_string_literal: true

module Salesforce
  class GuidedSyncConfigurationGroup < ActiveRecord::Base
    self.table_name = "crm_sync_configuration_groups"

    belongs_to :configuration, class_name: "Salesforce::GuidedSyncConfiguration"
    belongs_to :group
  end
end

# == Schema Information
#
# Table name: crm_sync_configuration_groups
#
#  id               :bigint           not null, primary key
#  configuration_id :bigint           not null
#  group_id         :integer          not null
#
# Indexes
#
#  idx_crm_sync_configuration_groups_on_configuration_and_group  (configuration_id,group_id) UNIQUE
#  idx_crm_sync_configuration_groups_on_group_and_configuration  (group_id,configuration_id) UNIQUE
#
