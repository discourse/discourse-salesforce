# frozen_string_literal: true

module Salesforce
  module GuidedSyncEndpoint
    extend ActiveSupport::Concern

    included { prepend_before_action :ensure_configurations_enabled }

    private

    def render_connection_error(error, provider:)
      ConnectionError.log(error, operation: action_name)
      category = ConnectionError.category(error)
      render json: {
               errors: [I18n.t("#{provider}.error.connection.#{category}")],
               error_type: category,
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
