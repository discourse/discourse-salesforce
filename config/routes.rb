# frozen_string_literal: true

Salesforce::Engine.routes.draw do
  post "/persons/create" => "persons#create"
  post "/cases/sync" => "cases#sync"
  delete "/cases/:id" => "cases#destroy"
  get "/admin/authorize" => "admin#authorize"
end

Discourse::Application.routes.draw { mount ::Salesforce::Engine, at: "salesforce" }
