# frozen_string_literal: true

module ::Hubspot
  class ContactPropertiesController < ::Admin::AdminController
    requires_plugin ::Salesforce::PLUGIN_NAME

    include DiscourseCrm::GuidedSyncEndpoint

    def index
      raise Discourse::NotFound unless SyncProvider.enabled?

      api = Api.new
      properties = api.cached_properties(refresh: params[:refresh] == "true")
      render json: {
               properties: properties,
               fields: api.cached_writable_fields("contact"),
               custom_sources: DiscourseCrm::UserSyncSources.custom_sources,
             }
    rescue InvalidCredentials, InvalidApiResponse, Faraday::Error => error
      render_connection_error(error, provider: "hubspot")
    end
  end
end
