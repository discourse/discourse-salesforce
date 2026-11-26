# frozen_string_literal: true

module DiscourseCrm
  class Segment::Preview
    include Service::Base

    params do
      attribute :configuration_id, :integer
      attribute :conditions

      validates :configuration_id, presence: true
      validates :conditions, presence: true
    end

    policy :can_manage
    model :configuration
    model :pulled_properties
    model :segment, :instantiate_segment
    policy :properties_are_pulled
    model :preview, :evaluate_segment

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
      DiscourseCrm::Segment.new(configuration:, name: "preview", conditions: params.conditions)
    end

    def properties_are_pulled(segment:, pulled_properties:)
      segment.missing_properties(pulled_properties).empty?
    end

    def evaluate_segment(segment:)
      DiscourseCrm::SegmentEvaluation.preview(segment)
    end
  end
end
