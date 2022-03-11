# frozen_string_literal: true

module Salesforce
  class CasesController < ::Admin::AdminController

    def sync
      params.require(:topic_id)
      topic = Topic.find(params[:topic_id])
      salesforce_case = Case.sync!(topic)
      render_serialized(salesforce_case, CaseSerializer)
    end
  end
end
