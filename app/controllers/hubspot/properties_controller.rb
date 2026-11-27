# frozen_string_literal: true

module ::Hubspot
  class PropertiesController < ::Admin::AdminController
    requires_plugin ::Salesforce::PLUGIN_NAME

    include DiscourseCrm::GuidedSyncEndpoint

    def index
      raise Discourse::NotFound unless SyncProvider.enabled?
      object = params.require(:object)
      raise Discourse::InvalidParameters.new(:object) unless Api::OBJECT_PATHS.key?(object)

      api = Api.new
      payload = {
        properties:
          InboundUsersFlow.pull_fields(object, api: api, refresh: params[:refresh] == "true"),
      }
      if object == "contact"
        payload[:fields] = api.cached_writable_fields(object)
        payload[:custom_sources] = DiscourseCrm::UserSyncSources.custom_sources
        payload[:destinations] = DiscourseCrm::UserSyncDestinations.all
      end
      render json: payload
    rescue InvalidCredentials, InvalidApiResponse, Faraday::Error => error
      render_connection_error(error, provider: "hubspot")
    end
  end
end
