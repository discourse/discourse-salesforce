# frozen_string_literal: true

module DiscourseCrm
  class Segment < ActiveRecord::Base
    self.table_name = "crm_segments"

    COMBINATORS = %w[all any].freeze
    OPERATORS = %w[equals not_equals contains not_contains set not_set].freeze
    VALUELESS_OPERATORS = %w[set not_set].freeze
    CONDITION_KEYS = %w[id object property operator value].freeze
    MAX_CONDITIONS = 20
    MAX_FLAIR_PROPERTIES = 10
    UNSUPPORTED_FLAIR_GROUP_IDS = [
      Group::AUTO_GROUPS[:everyone],
      Group::AUTO_GROUPS[:anonymous_users],
    ].freeze
    MAX_NAME_LENGTH = 60
    MAX_VALUE_LENGTH = 255

    belongs_to :configuration, class_name: "DiscourseCrm::SyncConfiguration"
    belongs_to :group, optional: true
    has_many :members, class_name: "DiscourseCrm::SegmentMember", dependent: :delete_all

    validates :configuration, presence: true
    validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
    validates :group_id, uniqueness: true, allow_nil: true
    validate :configuration_is_a_pull
    validate :conditions_shape
    validate :group_shape
    validate :flair_shape

    scope :with_flair, -> { where(flair_enabled: true) }

    def conditions=(value)
      super(value.is_a?(Hash) ? value.deep_stringify_keys : value)
    end

    def combinator
      conditions.keys.first if conditions.is_a?(Hash)
    end

    def condition_list
      list = conditions[combinator] if conditions.is_a?(Hash)
      list.is_a?(Array) ? list.select { |condition| condition.is_a?(Hash) } : []
    end

    def connection_changed?
      configuration.connection_changed?
    end

    def missing_properties(pulled)
      pulled_ids = pulled.map { |property| property_id(property[:object], property[:name]) }
      condition_list
        .map { |condition| property_id(condition["object"], condition["property"]) }
        .uniq
        .reject { |id| pulled_ids.include?(id) }
    end

    def flair_property_ids
      return [] unless flair_enabled
      [flair_text_property, *flair_properties].compact.uniq
    end

    def flair_visible_to?(user)
      flair_group_ids.empty? || (user.present? && user.in_any_groups?(flair_group_ids))
    end

    def missing_flair_properties(pulled)
      pulled_ids = pulled.map { |property| property_id(property[:object], property[:name]) }
      flair_property_ids.reject { |id| pulled_ids.include?(id) }
    end

    def matches?(records)
      records.any? { |record| record_matches?(record) }
    end

    private

    def property_id(object, name)
      "#{object}.#{name}"
    end

    def record_matches?(record)
      results = condition_list.map { |condition| condition_matches?(condition, record) }
      combinator == "all" ? results.all? : results.any?
    end

    def condition_matches?(condition, record)
      source = condition_source(condition, record)
      return false if source.nil? || !source.data.key?(condition["property"])
      actual = source.data[condition["property"]].to_s.strip.downcase
      expected = condition["value"].to_s.strip.downcase
      case condition["operator"]
      when "set"
        actual.present?
      when "not_set"
        actual.blank?
      when "equals"
        actual == expected
      when "not_equals"
        actual != expected
      when "contains"
        actual.include?(expected)
      when "not_contains"
        !actual.include?(expected)
      end
    end

    def condition_source(condition, record)
      return record if condition["object"] == record.object
      company = record.company
      company if company && condition["object"] == company.object
    end

    def configuration_is_a_pull
      errors.add(:configuration_id, :not_pull) if configuration && !configuration.inbound?
    end

    def conditions_shape
      unless conditions.is_a?(Hash) && conditions.keys.size == 1 &&
               COMBINATORS.include?(combinator) && conditions[combinator].is_a?(Array) &&
               conditions[combinator].any?
        errors.add(:conditions, :invalid)
        return
      end
      list = conditions[combinator]
      errors.add(:conditions, :too_many, count: MAX_CONDITIONS) if list.size > MAX_CONDITIONS
      if list.any? { |condition| !condition_valid?(condition) }
        return errors.add(:conditions, :invalid)
      end
      errors.add(:conditions, :taken) if list.map { |c| c.except("id") }.uniq.size != list.size
    end

    def condition_valid?(condition)
      return false unless condition.is_a?(Hash) && (condition.keys - CONDITION_KEYS).empty?
      return false unless condition["id"].is_a?(Integer)
      return false unless condition["object"].is_a?(String) && condition["object"].present?
      return false unless condition["property"].is_a?(String) && condition["property"].present?
      return false if OPERATORS.exclude?(condition["operator"])
      value = condition["value"]
      return false unless value.nil? || value.is_a?(String)
      return false if value.to_s.length > MAX_VALUE_LENGTH
      VALUELESS_OPERATORS.include?(condition["operator"]) || value.to_s.strip.present?
    end

    def group_shape
      if group_id.present?
        errors.add(:group_id, :not_found) if group.nil?
        errors.add(:group_id, :automatic) if group&.automatic?
      elsif remove_unmatched
        errors.add(:remove_unmatched, :requires_group)
      end
    end

    def flair_shape
      unless flair_text_property.nil? || property_id?(flair_text_property)
        errors.add(:flair_text_property, :invalid)
      end
      unless flair_properties.is_a?(Array) && flair_properties.all? { |id| property_id?(id) } &&
               flair_properties.uniq.size == flair_properties.size
        errors.add(:flair_properties, :invalid)
      end
      if flair_properties.is_a?(Array) && flair_properties.size > MAX_FLAIR_PROPERTIES
        errors.add(:flair_properties, :too_many, count: MAX_FLAIR_PROPERTIES)
      end
      ids = Array(flair_group_ids)
      added = ids - Array(flair_group_ids_in_database)
      if ids.any? { |id| !id.is_a?(Integer) || UNSUPPORTED_FLAIR_GROUP_IDS.include?(id) } ||
           ids.uniq.size != ids.size || Group.where(id: added).count != added.size
        errors.add(:flair_group_ids, :invalid)
      end
    end

    def property_id?(value)
      value.is_a?(String) && value.match?(/\A[^.\s]+\.\S+\z/)
    end
  end
end

# == Schema Information
#
# Table name: crm_segments
#
#  id                  :bigint           not null, primary key
#  conditions          :jsonb            not null
#  flair_enabled       :boolean          default(FALSE), not null
#  flair_group_ids     :integer          default([]), not null, is an Array
#  flair_properties    :jsonb            not null
#  flair_text_property :string
#  last_evaluated_at   :datetime
#  name                :string           not null
#  remove_unmatched    :boolean          default(FALSE), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  configuration_id    :bigint           not null
#  group_id            :integer
#
# Indexes
#
#  index_crm_segments_on_configuration_id  (configuration_id)
#  index_crm_segments_on_group_id          (group_id) UNIQUE WHERE (group_id IS NOT NULL)
#
