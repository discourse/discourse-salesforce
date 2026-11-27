# frozen_string_literal: true

module DiscourseCrm
  class Segment::Create
    include Service::Base

    params do
      attribute :configuration_id, :integer
      attribute :name, :string
      attribute :conditions
      attribute :group_id, :integer
      attribute :remove_unmatched, :boolean, default: false
      attribute :flair_enabled, :boolean, default: false
      attribute :flair_text_property, :string
      attribute :flair_properties, :array, default: []
      attribute :flair_group_ids, :array, default: []

      validates :configuration_id, presence: true
      validates :name, presence: true, length: { maximum: DiscourseCrm::Segment::MAX_NAME_LENGTH }
      validates :conditions, presence: true

      validate :flair_properties_are_property_ids
      validate :flair_group_ids_are_group_ids

      def flair_properties_are_property_ids
        return if flair_properties.is_a?(Array) && flair_properties.all?(String)
        errors.add(:flair_properties, :invalid)
      end

      def flair_group_ids_are_group_ids
        return if flair_group_ids.is_a?(Array) && flair_group_ids.all?(Integer)
        errors.add(:flair_group_ids, :invalid)
      end
    end

    policy :can_manage
    model :configuration
    model :pulled_properties
    model :segment, :instantiate_segment
    policy :properties_are_pulled
    step :save_segment
    step :enqueue_evaluation

    private

    def can_manage(guardian:)
      SiteSetting.crm_segments_enabled && guardian.is_admin? &&
        guardian.user.upcoming_change_enabled?(:enable_guided_sync_configuration)
    end

    def fetch_configuration(params:)
      DiscourseCrm::SyncConfiguration.active.inbound.find_by(id: params.configuration_id)
    end

    def fetch_pulled_properties(configuration:)
      configuration.pulled_properties
    end

    def instantiate_segment(params:, configuration:)
      DiscourseCrm::Segment.new(
        configuration:,
        name: params.name.strip,
        conditions: params.conditions,
        group_id: params.group_id,
        remove_unmatched: params.remove_unmatched,
        flair_enabled: params.flair_enabled,
        flair_text_property: params.flair_enabled ? params.flair_text_property.presence : nil,
        flair_properties: params.flair_enabled ? params.flair_properties : [],
        flair_group_ids: params.flair_group_ids,
      )
    end

    def properties_are_pulled(segment:, pulled_properties:)
      segment.missing_properties(pulled_properties).empty? &&
        segment.missing_flair_properties(pulled_properties).empty?
    end

    def save_segment(segment:)
      segment.save!
    rescue ActiveRecord::RecordNotUnique
      segment.errors.add(:group_id, :taken)
      fail!("group already targeted")
    end

    def enqueue_evaluation(segment:)
      Jobs.enqueue(Jobs::DiscourseCrm::EvaluateSegments, configuration_id: segment.configuration_id)
    end
  end
end
