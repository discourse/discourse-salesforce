# frozen_string_literal: true

module Salesforce
  class AdminController < ::Admin::AdminController
    requires_plugin PLUGIN_NAME

    skip_before_action :check_xhr, :preload_json

    def authorize
      redirect_to "#{SiteSetting.salesforce_authorization_server_url}/services/oauth2/authorize?client_id=#{SiteSetting.salesforce_client_id}&redirect_uri=#{Discourse.base_url}&response_type=code",
                  allow_other_host: true
    end
  end
end
