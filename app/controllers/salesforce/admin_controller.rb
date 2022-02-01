# frozen_string_literal: true

module Salesforce
  class AdminController < ::Admin::AdminController
    skip_before_action :check_xhr, :preload_json

    def authorize
      respond_to do |format|
        format.html do
          redirect_to "https://login.salesforce.com/services/oauth2/authorize?client_id=#{SiteSetting.salesforce_client_id}&redirect_uri=#{Discourse.base_url}&response_type=token"
        end
      end
    end
  end
end
