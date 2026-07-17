# frozen_string_literal: true

module Salesforce
  class PersonsController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    before_action :find_user
    before_action :find_post
    attr_accessor :user, :sync_post

    def create
      type = params.require(:type).capitalize
      raise ArgumentError.new :type if [Lead::OBJECT_NAME, Contact::OBJECT_NAME].exclude?(type)

      begin
        klass = "::Salesforce::#{type}".constantize
        salesforce_id = klass.create!(user) || user.custom_fields[klass::ID_FIELD]
        publish_person_synced(klass::ID_FIELD, salesforce_id)
        render json: success_json
      rescue => e
        render json: { errors: [e.message] }, status: :unprocessable_content
      end
    end

    def create_contact
      begin
        Contact.create!(user)
        render json: success_json
      rescue => e
        render json: { errors: [e.message] }, status: :unprocessable_content
      end
    end

    def find_user
      params.require(:user_id)
      user_id = params[:user_id]
      @user = User.find_by(id: user_id)
      raise Discourse::InvalidParameters.new(:user_id) if user.blank?
    end

    def find_post
      return if params[:post_id].blank?

      @sync_post = Post.find_by(id: params[:post_id])
      if sync_post.blank? || sync_post.user_id != user.id
        raise Discourse::InvalidParameters.new(:post_id)
      end
    end

    def publish_person_synced(field, value)
      return if sync_post.blank? || value.blank?

      MessageBus.publish(
        "/topic/#{sync_post.topic_id}",
        { type: "salesforce_person_synced", user_id: user.id, field: field, value: value },
        group_ids: [Group::AUTO_GROUPS[:admins]],
      )
    end
  end
end
