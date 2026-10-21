# frozen_string_literal: true

module Salesforce
  class CasesController < ::ApplicationController
    requires_login
    requires_plugin PLUGIN_NAME

    before_action(only: :sync) { guardian.ensure_can_sync_salesforce_cases! }
    before_action(only: :destroy) { guardian.ensure_can_delete_salesforce_cases! }

    rescue_from "Salesforce::InvalidCredentials" do
      render json: {
               error: I18n.t("salesforce.error.invalid_client_credentials"),
             },
             status: :bad_gateway
    end

    rescue_from "Salesforce::InvalidApiResponse" do |error|
      render json: {
               errors: [error.message.presence || I18n.t("salesforce.error.invalid_response")],
             },
             status: :unprocessable_content
    end

    def sync
      params.require(:topic_id)
      topic = Topic.find(params[:topic_id])
      guardian.ensure_can_see!(topic)

      salesforce_case = Case.sync!(topic)
      render_serialized(salesforce_case, CaseSerializer)
    end

    def destroy
      salesforce_case = Case.find(params[:id])
      guardian.ensure_can_see!(salesforce_case.topic)

      salesforce_case.delete_and_unlink!
      head :no_content
    end
  end
end
