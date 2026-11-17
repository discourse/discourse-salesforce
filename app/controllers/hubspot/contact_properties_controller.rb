# frozen_string_literal: true

module ::Hubspot
  class ContactPropertiesController < ::Admin::AdminController
    requires_plugin ::Salesforce::PLUGIN_NAME

    include ::Salesforce::GuidedSyncEndpoint

    def index
      raise Discourse::NotFound unless SyncProvider.enabled?

      render json: { properties: Api.cached_properties(refresh: params[:refresh] == "true") }
    rescue InvalidCredentials, InvalidApiResponse, Faraday::Error => error
      render_connection_error(error, provider: "hubspot")
    end
  end
end
