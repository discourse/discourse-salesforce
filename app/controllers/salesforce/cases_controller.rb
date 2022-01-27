# frozen_string_literal: true

module Salesforce
  class CasesController < ::Admin::AdminController

    def sync
      params.require(:topic_id)
      topic = Topic.find(params[:topic_id])
      _case = Case.sync!(topic)
      render_serialized(_case, CaseSerializer)
    end
  end
end
