# frozen_string_literal: true

Salesforce::Engine.routes.draw do
  post "/persons/create" => "persons#create"
  post "/cases/sync" => "cases#sync"
  get "/admin/authorize" => "admin#authorize"
end

Discourse::Application.routes.draw { mount ::Salesforce::Engine, at: "salesforce" }
