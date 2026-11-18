# frozen_string_literal: true

module Salesforce
  class FieldsController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME
    include DiscourseCrm::GuidedSyncEndpoint

    def index
      raise Discourse::NotFound unless SyncProvider.enabled?
      object = params.require(:object)
      raise Discourse::InvalidParameters.new(:object) if OutboundUsersFlow.objects.exclude?(object)

      render json: {
               fields: Api.cached_writable_fields(object, refresh: params[:refresh] == "true"),
               custom_sources: DiscourseCrm::UserSyncSources.custom_sources,
             }
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error, provider: "salesforce")
    end
  end
end
