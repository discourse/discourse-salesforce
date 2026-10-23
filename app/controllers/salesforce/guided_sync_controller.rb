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

      render json: { fields: Api.new.writable_fields(object) }
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError
      render json: { errors: [I18n.t("salesforce.error.fields_unavailable")] }, status: :bad_gateway
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
            :onJoin,
            :onChange,
            :backfill,
            mappings: %i[id source destination policy],
          )
          .to_h
      record = GuidedSyncConfiguration.save!(configuration, id: params[:id], guardian: guardian)
      render json: { configuration: record }, status: params[:id] ? :ok : :created
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError
      render json: { errors: [I18n.t("salesforce.error.fields_unavailable")] }, status: :bad_gateway
    end

    def destroy_configuration
      GuidedSyncConfiguration.destroy!(id: params[:id], guardian: guardian)
      head :no_content
    end

    def index
      render html: "", layout: "admin"
    end

    private

    def ensure_configurations_enabled
      unless current_user&.upcoming_change_enabled?(:enable_salesforce_configurations)
        head :not_found
      end
    end
  end
end
