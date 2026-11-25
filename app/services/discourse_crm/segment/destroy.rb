# frozen_string_literal: true

module DiscourseCrm
  class Segment::Destroy
    include Service::Base

    params do
      attribute :segment_id, :integer

      validates :segment_id, presence: true
    end

    policy :can_manage
    model :segment
    step :destroy_segment

    private

    def can_manage(guardian:)
      SiteSetting.crm_segments_enabled && guardian.is_admin? &&
        guardian.user.upcoming_change_enabled?(:enable_guided_sync_configuration)
    end

    def fetch_segment(params:)
      DiscourseCrm::Segment.find_by(id: params.segment_id)
    end

    def destroy_segment(segment:)
      segment.destroy!
    end
  end
end
