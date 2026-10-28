# frozen_string_literal: true

module Salesforce
  class GuidedSyncController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    prepend_before_action :ensure_configurations_enabled

    def configurations
      render json: {
               configurations:
                 GuidedSyncConfiguration.all.map { |record|
                   record.merge(
                     "sync_status" =>
                       PluginStore.get(PLUGIN_NAME, "configuration_status:#{record["id"]}"),
                   )
                 },
               credentials_configured: Api.has_credentials?,
               groups: GuidedSyncConfiguration.available_groups,
             }
    end

    def fields
      object = params.require(:object)
      raise Discourse::InvalidParameters.new(:object) if %w[Lead Contact].exclude?(object)

      render json: {
               fields: Api.new.writable_fields(object),
               custom_sources: UserSyncSources.custom_sources,
             }
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error)
    end

    def preview_users
      users =
        UserSyncPreview.users(params[:groups] || params.require(:group), query: params[:q]).limit(
          30,
        )
      render json: {
               users:
                 users.map { |user| { id: user.id, username: user.username, name: user.name } },
             }
    end

    def preview
      configuration =
        params
          .require(:configuration)
          .permit(:group, :object, groups: [], mappings: %i[id source destination policy value])
          .to_h
      render json: UserSyncPreview.call(configuration, user_id: params[:user_id])
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error)
    end

    def save_configuration
      configuration =
        params
          .require(:configuration)
          .permit(
            :name,
            :kind,
            :previewUser,
            :group,
            :object,
            :schedule,
            :backfill,
            groups: [],
            mappings: %i[id source destination policy value],
          )
          .to_h
      record = GuidedSyncConfiguration.save!(configuration, id: params[:id], guardian: guardian)
      render json: { configuration: record }, status: params[:id] ? :ok : :created
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error)
    end

    def destroy_configuration
      GuidedSyncConfiguration.destroy!(id: params[:id], guardian: guardian)
      head :no_content
    end

    def index
      render html: "", layout: "admin"
    end

    private

    def render_connection_error(error)
      ConnectionError.log(error, operation: action_name)
      render json: {
               errors: [I18n.t("salesforce.error.connection.#{ConnectionError.category(error)}")],
               error_type: ConnectionError.category(error),
             },
             status: :bad_gateway
    end

    def ensure_configurations_enabled
      unless current_user&.upcoming_change_enabled?(:enable_guided_sync_configuration)
        head :not_found
      end
    end
  end
end
