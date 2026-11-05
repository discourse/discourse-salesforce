# frozen_string_literal: true

module Salesforce
  class GuidedSyncController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    prepend_before_action :ensure_configurations_enabled

    def configurations
      records = GuidedSyncConfiguration.includes(:groups).order(:id)
      render json: {
               configurations: serialize_data(records, GuidedSyncConfigurationSerializer),
               credentials_configured: Api.has_credentials?,
               groups: GuidedSyncConfiguration.available_groups,
             }
    end

    def fields
      object = params.require(:object)
      raise Discourse::InvalidParameters.new(:object) if %w[Lead Contact].exclude?(object)

      render json: {
               fields: Api.cached_writable_fields(object, refresh: params[:refresh] == "true"),
               custom_sources: UserSyncSources.custom_sources,
             }
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error)
    end

    def groups
      render json: { groups: GuidedSyncConfiguration.available_groups(query: params[:q]) }
    end

    def save_configuration
      configuration =
        params
          .require(:configuration)
          .permit(
            :name,
            :kind,
            :object,
            :schedule,
            :backfill,
            group_ids: [],
            mappings: %i[id source destination policy value],
          )
          .to_h
      record =
        GuidedSyncConfiguration.create_or_update!(
          configuration,
          id: params[:id],
          guardian: guardian,
        )
      render json: {
               configuration:
                 serialize_data(record, GuidedSyncConfigurationSerializer, root: false),
             },
             status: params[:id] ? :ok : :created
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error)
    end

    def destroy_configuration
      GuidedSyncConfiguration.remove!(params[:id], guardian: guardian)
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
