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

      validates :configuration_id, presence: true
      validates :name, presence: true, length: { maximum: DiscourseCrm::Segment::MAX_NAME_LENGTH }
      validates :conditions, presence: true
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
      )
    end

    def properties_are_pulled(segment:, pulled_properties:)
      segment.missing_properties(pulled_properties).empty?
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
