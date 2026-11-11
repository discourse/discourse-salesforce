# frozen_string_literal: true

module Salesforce
  class Record < ActiveRecord::Base
    self.table_name = "crm_records"

    has_many :record_links,
             class_name: "Salesforce::RecordLink",
             primary_key: %i[provider account object external_id],
             foreign_key: %i[provider account object external_id]

    scope :within, ->(provider:, account:, object:) { where(provider:, account:, object:) }
    scope :hubspot, -> { where(provider: "hubspot") }

    def self.store_many!(rows)
      return if rows.empty?
      upsert_all(rows, unique_by: %i[provider account object external_id], update_only: %i[data])
    end
  end
end

# == Schema Information
#
# Table name: crm_records
#
#  id          :bigint           not null, primary key
#  account     :string           not null
#  data        :jsonb            not null
#  object      :string           not null
#  provider    :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  external_id :string           not null
#
# Indexes
#
#  idx_on_provider_account_object_external_id_e63c7950a7  (provider,account,object,external_id) UNIQUE
#
