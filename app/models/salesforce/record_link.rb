# frozen_string_literal: true

module Salesforce
  class RecordLink < ActiveRecord::Base
    self.table_name = "crm_record_links"

    scope :within, ->(provider:, account:, object:) { where(provider:, account:, object:) }
    scope :live, -> { where(converted_to_id: nil) }

    def self.read_many(provider:, account:, object:, user_ids:)
      within(provider:, account:, object:)
        .where(user_id: user_ids)
        .order(:user_id)
        .index_by(&:user_id)
    end

    def self.link!(provider:, account:, object:, user_id:, external_id:, converted_from_id: nil)
      link = find_or_initialize_by(provider:, account:, object:, user_id:)
      converted_from_id ||= link.converted_from_id if link.external_id == external_id
      link.assign_attributes(
        external_id:,
        converted_from_id:,
        converted_to_object: nil,
        converted_to_id: nil,
      )
      link.save! if link.new_record? || link.changed?
      link
    end

    def self.mark_converted!(
      provider:,
      account:,
      object:,
      user_id:,
      external_id:,
      to_object:,
      to_id:
    )
      link = find_or_initialize_by(provider:, account:, object:, user_id:)
      link.update!(external_id:, converted_to_object: to_object, converted_to_id: to_id)
      link
    end

    def self.unlink!(provider:, account:, object:, user_id:, external_id:)
      within(provider:, account:, object:).where(user_id:, external_id:).live.delete_all > 0
    end

    def converted?
      converted_to_id.present?
    end
  end
end

# == Schema Information
#
# Table name: crm_record_links
#
#  id                  :bigint           not null, primary key
#  account             :string           not null
#  converted_to_object :string
#  object              :string           not null
#  provider            :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  converted_from_id   :string
#  converted_to_id     :string
#  external_id         :string           not null
#  user_id             :integer          not null
#
# Indexes
#
#  idx_on_provider_account_object_external_id_e6565f303b  (provider,account,object,external_id)
#  idx_on_provider_account_object_user_id_2760c0fe2e      (provider,account,object,user_id) UNIQUE
#
