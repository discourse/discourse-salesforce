# frozen_string_literal: true

module Salesforce
  class FieldsController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME
    include DiscourseCrm::GuidedSyncEndpoint

    def index
      raise Discourse::NotFound unless SyncProvider.enabled?
      object = params.require(:object)
      flow = params[:direction] == "inbound" ? InboundUsersFlow : OutboundUsersFlow
      raise Discourse::InvalidParameters.new(:object) if flow.objects.exclude?(object)

      refresh = params[:refresh] == "true"
      if params[:direction] == "inbound"
        render json: {
                 fields: InboundUsersFlow.pull_fields(object, refresh: refresh),
                 destinations: DiscourseCrm::UserSyncDestinations.all,
               }
      else
        render json: {
                 fields: Api.cached_writable_fields(object, refresh: refresh),
                 custom_sources: DiscourseCrm::UserSyncSources.custom_sources,
               }
      end
    rescue Salesforce::InvalidCredentials,
           Salesforce::InvalidApiResponse,
           Faraday::Error,
           OpenSSL::PKey::RSAError => error
      render_connection_error(error, provider: "salesforce")
    end
  end
end
