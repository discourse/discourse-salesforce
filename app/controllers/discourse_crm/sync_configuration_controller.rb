# frozen_string_literal: true

module DiscourseCrm
  class SyncConfigurationController < ::Admin::AdminController
    requires_plugin ::Salesforce::PLUGIN_NAME

    include GuidedSyncEndpoint

    def configurations
      records = SyncConfiguration.includes(:groups).order(:id)
      render json: {
               configurations: serialize_data(records, SyncConfigurationSerializer),
               providers: SyncConfiguration.available_providers,
               targets: SyncConfiguration.available_targets,
               pull_targets: SyncConfiguration.available_targets("inbound"),
               groups: SyncConfiguration.available_groups,
             }
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
            mappings: %i[id object source destination policy value],
          )
          .to_h
      record =
        SyncConfiguration.create_or_update!(configuration, id: params[:id], guardian: guardian)
      render json: {
               configuration: serialize_data(record, SyncConfigurationSerializer, root: false),
             },
             status: params[:id] ? :ok : :created
    rescue ::Hubspot::InvalidPropertyValue => error
      render json: {
               errors: [I18n.t("hubspot.error.invalid_property_value", property: error.property)],
               error_type: "invalid_property_value",
             },
             status: :unprocessable_entity
    rescue InvalidMapping => error
      render json: {
               errors: [error.message],
               error_type: "invalid_mapping",
               mapping_index: error.mapping_index,
             }.compact,
             status: :unprocessable_entity
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
