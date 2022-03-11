# frozen_string_literal: true

class Salesforce::PersonsController < Admin::AdminController
  before_action :find_user
  attr_accessor :user

  def create
    begin
      Salesforce::Person.create!(params.require(:type), user)
      render json: success_json
    rescue => e
      render json: { errors: [e.message] }, status: 422
    end
  end

  def create_contact
    begin
      Salesforce::Contact.create!(user)
      render json: success_json
    rescue => e
      render json: { errors: [e.message] }, status: 422
    end
  end

  def find_user
    params.require(:user_id)
    user_id = params[:user_id]
    @user = User.find_by(id: user_id)
    raise Discourse::InvalidParameters.new(:user_id) if user.blank?
  end
end
