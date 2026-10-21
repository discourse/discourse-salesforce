# frozen_string_literal: true

module Salesforce
  class GuidedSyncController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    def configurations
      render json: {
               configurations: GuidedSyncConfiguration.all,
               connection: PluginStore.get(PLUGIN_NAME, "guided_sync_connection"),
             }
    end

    def save_connection
      environment = params.require(:environment)
      if %w[sandbox production].exclude?(environment)
        raise Discourse::InvalidParameters.new(:environment)
      end
      connection = { "environment" => environment }
      PluginStore.set(PLUGIN_NAME, "guided_sync_connection", connection)
      render json: { connection: connection }
    end

    def save_configuration
      configuration =
        params
          .require(:configuration)
          .permit(
            :name,
            :kind,
            :category,
            :onCreate,
            :onEdit,
            :outboundReplies,
            :inboundReplies,
            :environment,
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
      if connection = PluginStore.get(PLUGIN_NAME, "guided_sync_connection")
        configuration["environment"] = connection["environment"]
      end
      record = GuidedSyncConfiguration.save!(configuration, id: params[:id], guardian: guardian)
      render json: { configuration: record }, status: params[:id] ? :ok : :created
    rescue GuidedSyncConfiguration::DeletionError => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    def destroy_configuration
      GuidedSyncConfiguration.destroy!(id: params[:id], guardian: guardian)
      head :no_content
    rescue GuidedSyncConfiguration::DeletionError => error
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    def index
      render html: "", layout: "admin"
    end
  end
end
