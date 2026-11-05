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
