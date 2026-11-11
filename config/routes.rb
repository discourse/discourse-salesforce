# frozen_string_literal: true

Salesforce::Engine.routes.draw do
  post "/persons/create" => "persons#create"
  delete "/persons/contact" => "persons#unlink_contact"
  post "/cases/sync" => "cases#sync"
  delete "/cases/:id" => "cases#destroy"
  get "/admin/guided-sync/fields" => "sync_configuration#fields"
  get "/admin/hubspot/contact-properties" => "/hubspot/contact_properties#index"
  get "/admin/guided-sync/groups" => "sync_configuration#groups"
  get "/admin/guided-sync/configurations" => "sync_configuration#configurations"
  post "/admin/guided-sync/configurations" => "sync_configuration#save_configuration"
  put "/admin/guided-sync/configurations/:id" => "sync_configuration#save_configuration"
  delete "/admin/guided-sync/configurations/:id" => "sync_configuration#destroy_configuration"
  get "/admin/authorize" => "admin#authorize"
end

Discourse::Application.routes.draw do
  mount ::Salesforce::Engine, at: "salesforce"

  get "/admin/plugins/discourse-salesforce/configurations" => "salesforce/sync_configuration#index",
      :constraints => AdminConstraint.new
end
