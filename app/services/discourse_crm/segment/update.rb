# frozen_string_literal: true

module DiscourseCrm
  class Segment::Update
    include Service::Base

    params do
      attribute :segment_id, :integer
      attribute :name, :string
      attribute :conditions
      attribute :group_id, :integer
      attribute :remove_unmatched, :boolean, default: false

      validates :segment_id, presence: true
      validates :name, presence: true, length: { maximum: DiscourseCrm::Segment::MAX_NAME_LENGTH }
      validates :conditions, presence: true
    end

    policy :can_manage
    model :segment
    model :pulled_properties
    policy :properties_are_pulled
    step :save_segment
    step :enqueue_evaluation

    private

    def can_manage(guardian:)
      SiteSetting.crm_segments_enabled && guardian.is_admin? &&
        guardian.user.upcoming_change_enabled?(:enable_guided_sync_configuration)
    end

    def fetch_segment(params:)
      DiscourseCrm::Segment
        .find_by(id: params.segment_id)
        &.tap do |segment|
          segment.assign_attributes(
            name: params.name.strip,
            conditions: params.conditions,
            group_id: params.group_id,
            remove_unmatched: params.remove_unmatched,
            last_evaluated_at: nil,
          )
        end
    end

    def fetch_pulled_properties(segment:)
      segment.configuration.pulled_properties
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
