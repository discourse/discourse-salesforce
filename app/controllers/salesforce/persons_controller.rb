# frozen_string_literal: true

class Salesforce::PersonsController < Admin::AdminController
  before_action :find_topic
  attr_accessor :topic

  def create
    begin
      Salesforce::Person.create!(params.require(:type), topic.user)
      render json: success_json
    rescue => e
      render json: { errors: [e.message] }, status: 422
    end
  end

  def create_contact
    begin
      Salesforce::Contact.create!(topic.user)
      render json: success_json
    rescue => e
      render json: { errors: [e.message] }, status: 422
    end
  end

  def find_topic
    params.require(:topic_id)
    topic_id = params[:topic_id]
    @topic = Topic.find_by(id: topic_id)
  end
end
