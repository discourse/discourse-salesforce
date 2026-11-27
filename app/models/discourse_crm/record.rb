# frozen_string_literal: true

module DiscourseCrm
  class Record < ActiveRecord::Base
    self.table_name = "crm_records"

    has_many :record_links,
             -> { where(direction: "inbound") },
             class_name: "DiscourseCrm::RecordLink",
             primary_key: %i[provider account object external_id],
             foreign_key: %i[provider account object external_id]
    belongs_to :company,
               -> { where(object: "company") },
               class_name: "DiscourseCrm::Record",
               primary_key: %i[provider account external_id],
               foreign_key: %i[provider account company_external_id],
               optional: true

    scope :within, ->(provider:, account:, object:) { where(provider:, account:, object:) }
    scope :hubspot, -> { where(provider: "hubspot") }

    def self.store_many!(rows)
      return [] if rows.empty?
      upsert_all(
        rows,
        unique_by: %i[provider account object external_id],
        on_duplicate: Arel.sql(<<~SQL),
          data = EXCLUDED.data, company_external_id = EXCLUDED.company_external_id, updated_at = EXCLUDED.updated_at
          WHERE (crm_records.data, crm_records.company_external_id) IS DISTINCT FROM (EXCLUDED.data, EXCLUDED.company_external_id)
        SQL
        returning: %w[external_id],
      ).pluck("external_id")
    end

    # Kept apart from store_many!, so a record whose stored fields did not change is not
    # reported as changed when only its modification time moved.
    def self.store_crm_modified!(provider:, account:, object:, modified_by_id:)
      rows =
        modified_by_id.filter_map do |external_id, time|
          { external_id:, modified: time.utc.iso8601(6) } if time
        end
      return if rows.empty?
      DB.exec(<<~SQL, provider:, account:, object:, rows: rows.to_json)
        UPDATE crm_records r
        SET crm_modified_at = v.modified
        FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS v(external_id text, modified timestamp)
        WHERE r.provider = :provider
          AND r.account = :account
          AND r.object = :object
          AND r.external_id = v.external_id
          AND r.crm_modified_at IS DISTINCT FROM v.modified
      SQL
    end
  end
end

# == Schema Information
#
# Table name: crm_records
#
#  id                  :bigint           not null, primary key
#  account             :string           not null
#  crm_modified_at     :datetime
#  data                :jsonb            not null
#  object              :string           not null
#  provider            :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  company_external_id :string
#  external_id         :string           not null
#
# Indexes
#
#  idx_on_provider_account_company_external_id_f3a61016eb  (provider,account,company_external_id)
#  idx_on_provider_account_object_external_id_e63c7950a7   (provider,account,object,external_id) UNIQUE
#
