# frozen_string_literal: true

module Salesforce
  class CasesController < ::Admin::AdminController
    before_action :find_topic
    attr_accessor :topic

    def sync
      begin
        Case.sync!(topic)
        render json: success_json
      rescue => e
        render json: { errors: [e.message] }, status: 422
      end
    end

    def find_topic
      params.require(:topic_id)
      topic_id = params[:topic_id]
      @topic = ::Topic.find_by(id: topic_id)
    end
  end
end
