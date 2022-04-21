# frozen_string_literal: true

module Salesforce
  class PersonsController < ::Admin::AdminController
    before_action :find_user
    attr_accessor :user

    def create
      type = params.require(:type).capitalize
      raise ArgumentError.new :type if [Lead::OBJECT_NAME, Contact::OBJECT_NAME].exclude?(type)

      begin
        "::Salesforce::#{type}".constantize.create!(user)
        render json: success_json
      rescue => e
        render json: { errors: [e.message] }, status: 422
      end
    end

    def create_contact
      begin
        Contact.create!(user)
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
end
