# frozen_string_literal: true

module Salesforce
  class PersonsController < ::ApplicationController
    requires_login
    requires_plugin PLUGIN_NAME

    before_action :ensure_admin, except: :unlink_contact
    before_action(only: :unlink_contact) { guardian.ensure_can_unlink_salesforce_contacts! }

    before_action :find_user
    before_action :find_post
    attr_accessor :user, :sync_post

    def create
      type = params.require(:type).capitalize
      raise ArgumentError.new :type if [Lead::OBJECT_NAME, Contact::OBJECT_NAME].exclude?(type)
      if type == Lead::OBJECT_NAME && !::Salesforce.leads_enabled?
        raise Discourse::InvalidParameters.new(:type)
      end

      begin
        klass = "::Salesforce::#{type}".constantize
        salesforce_id =
          klass.create!(user, acting_user: current_user) || user.custom_fields[klass::ID_FIELD]
        publish_person_synced(klass::ID_FIELD, salesforce_id) if salesforce_id.present?
        render json: success_json
      rescue => e
        render json: { errors: [e.message] }, status: :unprocessable_content
      end
    end

    def unlink_contact
      params.require(:post_id)
      guardian.ensure_can_see!(sync_post)
      expected_id = params.require(:expected_contact_id)
      raise Discourse::InvalidParameters.new(:expected_contact_id) unless expected_id.is_a?(String)

      removed = Associations.unlink_contact!(user: user, expected_id: expected_id)
      if removed
        publish_person_synced(
          Contact::ID_FIELD,
          nil,
          expected_value: expected_id,
          group_ids: [Group::AUTO_GROUPS[:admins], Group::AUTO_GROUPS[:moderators]],
        )
      end
      head :no_content
    rescue Associations::ContactLinkChanged
      render json: { errors: [I18n.t("salesforce.error.contact_link_changed")] }, status: :conflict
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

    def publish_person_synced(
      field,
      value,
      group_ids: [Group::AUTO_GROUPS[:admins]],
      expected_value: nil
    )
      return if sync_post.blank?

      DistributedMutex.synchronize(
        "salesforce_person_create_#{user.id}",
        validity: ConfiguredUserSync::SYNC_LOCK_VALIDITY,
      ) do
        next if user.reload.custom_fields[field] != value

        data = { type: "salesforce_person_synced", user_id: user.id, field: field, value: value }
        data[:expected_value] = expected_value if expected_value
        MessageBus.publish("/topic/#{sync_post.topic_id}", data, group_ids: group_ids)
      end
    end
  end
end
