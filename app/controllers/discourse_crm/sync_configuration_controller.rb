# frozen_string_literal: true

module DiscourseCrm
  class SyncConfigurationController < ::Admin::AdminController
    requires_plugin "discourse-salesforce"

    prepend_before_action :ensure_configurations_enabled

    def configurations
      records = SyncConfiguration.includes(:groups).order(:id)
      render json: {
               configurations: serialize_data(records, SyncConfigurationSerializer),
               credentials_configured: Provider.available_targets.present?,
               targets: Provider.available_targets,
               groups: SyncConfiguration.available_groups,
             }
    end

    def fields
      object = params.require(:object)
      crm = Provider.new(params.fetch(:provider, "salesforce"))
      raise Discourse::InvalidParameters.new(:provider) unless crm.configured?
      raise Discourse::InvalidParameters.new(:object) if crm.objects.exclude?(object)

      render json: {
               fields:
                 crm.api_class.cached_writable_fields(object, refresh: params[:refresh] == "true"),
               custom_sources: UserSyncSources.custom_sources,
             }
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Hubspot::InvalidCredentials,
           Hubspot::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error)
    end

    def groups
      render json: { groups: SyncConfiguration.available_groups(query: params[:q]) }
    end

    def save_configuration
      configuration =
        params
          .require(:configuration)
          .permit(
            :name,
            :provider,
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
           Hubspot::InvalidCredentials,
           Hubspot::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error)
    end

    def destroy_configuration
      SyncConfiguration.remove!(params[:id], guardian: guardian)
      head :no_content
    end

    def index
      render html: "", layout: "admin"
    end

    private

    def render_connection_error(error)
      provider =
        (
          if error.is_a?(Hubspot::InvalidCredentials) || error.is_a?(Hubspot::InvalidApiResponse)
            "hubspot"
          else
            params[:provider] || params.dig(:configuration, :provider) || "salesforce"
          end
        )
      provider = "salesforce" if Provider::NAMES.exclude?(provider)
      ConnectionError.log(error, operation: action_name, provider: provider)
      render json: {
               errors: [I18n.t("#{provider}.error.connection.#{ConnectionError.category(error)}")],
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
