# frozen_string_literal: true

Salesforce::Engine.routes.draw do
  post "/persons/create" => "persons#create"
  post "/cases/sync" => "cases#sync"
  delete "/cases/:id" => "cases#destroy"
  get "/admin/guided-sync/preview-users" => "guided_sync#preview_users"
  post "/admin/guided-sync/preview" => "guided_sync#preview"
  get "/admin/guided-sync/fields" => "guided_sync#fields"
  get "/admin/guided-sync/configurations" => "guided_sync#configurations"
  post "/admin/guided-sync/configurations" => "guided_sync#save_configuration"
  put "/admin/guided-sync/configurations/:id" => "guided_sync#save_configuration"
  delete "/admin/guided-sync/configurations/:id" => "guided_sync#destroy_configuration"
  get "/admin/authorize" => "admin#authorize"
end

Discourse::Application.routes.draw do
  mount ::Salesforce::Engine, at: "salesforce"

  get "/admin/plugins/discourse-salesforce/configurations" => "salesforce/guided_sync#index",
      :constraints => AdminConstraint.new

  get "/admin/plugins/discourse-salesforce/guided-sync" => "salesforce/guided_sync#index",
      :constraints => AdminConstraint.new
end
