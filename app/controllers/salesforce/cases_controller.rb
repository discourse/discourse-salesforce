# frozen_string_literal: true

module Salesforce
  class CasesController < ::ApplicationController
    requires_login
    requires_plugin PLUGIN_NAME

    before_action { guardian.ensure_can_sync_salesforce_cases! }

    def sync
      params.require(:topic_id)
      topic = Topic.find(params[:topic_id])
      guardian.ensure_can_see!(topic)

      begin
        salesforce_case = Case.sync!(topic)
        render_serialized(salesforce_case, CaseSerializer)
      rescue Salesforce::InvalidCredentials
        render json: {
                 error: I18n.t("salesforce.error.invalid_client_credentials"),
               },
               status: :bad_gateway
      rescue Salesforce::InvalidApiResponse => e
        render json: {
                 errors: [e.message.presence || I18n.t("salesforce.error.invalid_response")],
               },
               status: :unprocessable_content
      end
    end
  end
end
