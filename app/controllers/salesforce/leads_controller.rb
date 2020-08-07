class Salesforce::LeadsController < Admin::AdminController
  def create
    begin
      params.require(:topic_id)
      topic_id = params[:topic_id]
      topic = Topic.find_by(id: topic_id)
      Salesforce::Lead.create!(topic.user)
      render json: success_json
    rescue => e
      render json: { errors: [e.message] }, status: 422
    end
  end
end
