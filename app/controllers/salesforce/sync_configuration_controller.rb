# frozen_string_literal: true

module Salesforce
  class SyncConfigurationController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    include GuidedSyncEndpoint

    def configurations
      records = SyncConfiguration.includes(:groups).order(:id)
      providers =
        SyncConfiguration::PROVIDERS
          .values
          .select(&:enabled?)
          .map do |definition|
            { name: definition.key, credentials_configured: definition.credentials? }
          end
      render json: {
               configurations: serialize_data(records, SyncConfigurationSerializer),
               providers: providers,
               groups: SyncConfiguration.available_groups,
             }
    end

    def fields
      object = params.require(:object)
      raise Discourse::InvalidParameters.new(:object) if OutboundUsersFlow.objects.exclude?(object)

      render json: {
               fields: Api.cached_writable_fields(object, refresh: params[:refresh] == "true"),
               custom_sources: UserSyncSources.custom_sources,
             }
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error, provider: "salesforce")
    end

    def groups
      render json: { groups: SyncConfiguration.available_groups(query: params[:q]) }
    end

    def save_configuration
      configuration =
        params
          .require(:configuration)
          .permit(
            :provider,
            :direction,
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
        SyncConfiguration.create_or_update!(configuration, id: params[:id], guardian: guardian)
      render json: {
               configuration: serialize_data(record, SyncConfigurationSerializer, root: false),
             },
             status: params[:id] ? :ok : :created
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           ::Hubspot::InvalidCredentials,
           ::Hubspot::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error, provider: configuration[:provider])
    end

    def destroy_configuration
      SyncConfiguration.remove!(params[:id], guardian: guardian)
      head :no_content
    end

    def index
      render html: "", layout: "admin"
    end
  end
end
