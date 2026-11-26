# frozen_string_literal: true

module Jobs
  module DiscourseCrm
    class EvaluateSegments < ::Jobs::Base
      def execute(args)
        return unless SiteSetting.crm_segments_enabled && ::DiscourseCrm::SyncConfiguration.enabled?
        configuration_id = args[:configuration_id]
        if args[:user_ids]
          ::DiscourseCrm::SegmentEvaluation.run_for_users(
            configuration_id:,
            user_ids: args[:user_ids],
          )
          return
        end
        after = ::DiscourseCrm::SegmentEvaluation.run_page(configuration_id:, after: args[:after])
        Jobs.enqueue(self.class, configuration_id:, after:) if after
      end
    end
  end
end
