# frozen_string_literal: true

module Jobs
  module DiscourseCrm
    class EvaluateSegments < ::Jobs::Base
      def execute(args)
        return unless SiteSetting.crm_segments_enabled && ::DiscourseCrm::SyncConfiguration.enabled?
        provider = args[:provider]
        account = args[:account]
        if args[:user_ids]
          ::DiscourseCrm::SegmentEvaluation.run_for_users(
            provider:,
            account:,
            user_ids: args[:user_ids],
          )
          return
        end
        after = ::DiscourseCrm::SegmentEvaluation.run_page(provider:, account:, after: args[:after])
        Jobs.enqueue(self.class, provider:, account:, after:) if after
      end
    end
  end
end
