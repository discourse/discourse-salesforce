# frozen_string_literal: true

module Salesforce
  class CasesController < ::Admin::AdminController
    def sync
      params.require(:topic_id)
      topic = Topic.find(params[:topic_id])

      begin
        salesforce_case = Case.sync!(topic)
        render_serialized(salesforce_case, CaseSerializer)
      rescue Salesforce::InvalidCredentials
        render json: { error: I18n.t("salesforce.error.invalid_client_credentials") }, status: 502
      end
    end
  end
end
