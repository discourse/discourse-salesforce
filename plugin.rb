# frozen_string_literal: true

# name: discourse-salesforce
# about: Integration features between Salesforce and Discourse
# version: 1.0
# author: Vinoth Kannan
# url: https://github.com/discourse/discourse-salesforce


enabled_site_setting :salesforce_enabled

register_asset 'stylesheets/salesforce.scss'
register_svg_icon "fab fa-salesforce" if respond_to?(:register_svg_icon)

after_initialize do

  module ::Salesforce
    PLUGIN_NAME = 'discourse-salesforce'.freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace Salesforce
    end
  end

  [
    '../app/controllers/salesforce/leads_controller.rb',
    '../app/models/salesforce/lead.rb',
    '../lib/salesforce/api.rb'
  ].each { |path| load File.expand_path(path, __FILE__) }

  Salesforce::Engine.routes.draw do
    post "/leads/create" => "leads#create"
  end

  Discourse::Application.routes.append do
    mount ::Salesforce::Engine, at: "salesforce"
  end
end
