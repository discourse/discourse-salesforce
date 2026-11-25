# frozen_string_literal: true

module DiscourseCrm
  class Segment::Preview
    include Service::Base

    params do
      attribute :provider, :string
      attribute :conditions

      validates :provider, inclusion: { in: DiscourseCrm::SyncConfiguration::PROVIDERS.keys }
      validates :conditions, presence: true
    end

    policy :can_manage
    model :account
    model :pulled_properties
    model :segment, :instantiate_segment
    policy :properties_are_pulled
    model :preview, :evaluate_segment

    private

    def can_manage(guardian:)
      SiteSetting.crm_segments_enabled && guardian.is_admin? &&
        guardian.user.upcoming_change_enabled?(:enable_guided_sync_configuration)
    end

    def fetch_account(params:)
      DiscourseCrm::SyncConfiguration.provider_definition(params.provider).account
    end

    def fetch_pulled_properties(params:, account:)
      DiscourseCrm::Segment.pulled_properties(provider: params.provider, account:)
    end

    def instantiate_segment(params:, account:)
      DiscourseCrm::Segment.new(
        provider: params.provider,
        account:,
        name: "preview",
        conditions: params.conditions,
      )
    end

    def properties_are_pulled(segment:, pulled_properties:)
      segment.missing_properties(pulled_properties).empty?
    end

    def evaluate_segment(segment:)
      DiscourseCrm::SegmentEvaluation.preview(segment)
    end
  end
end
