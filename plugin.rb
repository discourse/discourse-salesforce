# frozen_string_literal: true

# name: discourse-salesforce
# about: Integration features between Salesforce and Discourse
# version: 1.0
# author: Vinoth Kannan
# url: https://github.com/discourse/discourse-salesforce

gem 'jwt', '2.3.0'

require 'auth/oauth2_authenticator'
require 'omniauth-oauth2'
require 'openssl'
require 'base64'

enabled_site_setting :salesforce_enabled

register_asset 'stylesheets/salesforce.scss'
register_svg_icon "fab-salesforce" if respond_to?(:register_svg_icon)

require_relative 'lib/validators/salesforce_login_enabled_validator'

after_initialize do

  module ::Salesforce
    PLUGIN_NAME = 'discourse-salesforce'.freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace Salesforce
    end
  end

  [
    '../app/controllers/salesforce/admin_controller.rb',
    '../app/controllers/salesforce/persons_controller.rb',
    '../app/models/salesforce/case.rb',
    '../app/models/salesforce/person.rb',
    '../lib/salesforce/api.rb'
  ].each { |path| load File.expand_path(path, __FILE__) }

  Salesforce::Engine.routes.draw do
    post "/persons/create" => "persons#create"
  end

  add_admin_route 'salesforce.title', 'salesforce'

  Discourse::Application.routes.append do
    mount ::Salesforce::Engine, at: "salesforce"
    get '/admin/plugins/salesforce' => 'admin/plugins#index', constraints: AdminConstraint.new
    get '/admin/plugins/salesforce/index' => 'salesforce/admin#index', constraints: AdminConstraint.new
  end

  class ::OmniAuth::Strategies::Salesforce
    option :name, 'salesforce'

    option :client_options, site:  'https://login.salesforce.com',
                            authorize_url: '/services/oauth2/authorize',
                            token_url: '/services/oauth2/token'
  end
end

#
# Class is mostly cut and paste from MIT https://raw.githubusercontent.com/realdoug/omniauth-salesforce/master/lib/omniauth/strategies/salesforce.rb
class OmniAuth::Strategies::Salesforce < OmniAuth::Strategies::OAuth2

  MOBILE_USER_AGENTS =  'webos|ipod|iphone|ipad|android|blackberry|mobile'.freeze

  option :authorize_options, [
    :scope,
    :display,
    :immediate,
    :state,
    :prompt,
    :redirect_uri,
    :login_hint
  ]

  def request_phase
    req = Rack::Request.new(@env)
    options.update(req.params)
    ua = req.user_agent.to_s
    if !options.has_key?(:display)
      mobile_request = ua.downcase =~ Regexp.new(MOBILE_USER_AGENTS)
      options[:display] = mobile_request ? 'touch' : 'page'
    end
    super
  end

  def auth_hash
    signed_value = access_token.params['id'] + access_token.params['issued_at']
    raw_expected_signature = OpenSSL::HMAC.digest('sha256', options.client_secret.to_s, signed_value)
    expected_signature = Base64.strict_encode64 raw_expected_signature
    signature = access_token.params['signature']
    fail! "Salesforce user id did not match signature!" unless signature == expected_signature
    super
  end

  uid { raw_info['id'] }

  info do
    {
      'name'            => raw_info['display_name'],
      'email'           => raw_info['email'],
      'nickname'        => raw_info['nick_name'],
      'first_name'      => raw_info['first_name'],
      'last_name'       => raw_info['last_name'],
      'location'        => '',
      'description'     => '',
      'image'           => raw_info['photos']['thumbnail'] + "?oauth_token=#{access_token.token}",
      'phone'           => '',
      'urls'            => raw_info['urls']
    }
  end

  credentials do
    hash = {'token' => access_token.token}
    hash.merge!('instance_url' => access_token.params["instance_url"])
    hash.merge!('refresh_token' => access_token.refresh_token) if access_token.refresh_token
    hash
  end

  def raw_info
    access_token.options[:mode] = :header
    @raw_info ||= access_token.post(access_token['id']).parsed
  end

  extra do
    raw_info.merge({
      'instance_url' => access_token.params['instance_url'],
      'pod' => access_token.params['instance_url'],
      'signature' => access_token.params['signature'],
      'issued_at' => access_token.params['issued_at']
    })
  end

end

class Auth::SalesforceAuthenticator < Auth::OAuth2Authenticator
  def register_middleware(omniauth)
    omniauth.provider :salesforce,
                      setup: lambda { |env|
                        strategy = env['omniauth.strategy']
                        strategy.options[:client_id] = SiteSetting.salesforce_client_id
                        strategy.options[:client_secret] = SiteSetting.salesforce_client_secret
                        strategy.options[:redirect_uri] = "#{Discourse.base_url}/auth/salesforce/callback"
                      }
  end

  def enabled?
    SiteSetting.salesforce_login_enabled
  end
end

auth_provider pretty_name: 'Salesforce',
              icon: 'fab-salesforce',
              title: 'with Salesforce',
              message: 'Authentication with Salesforce (make sure pop up blockers are not enabled)',
              frame_width: 840,
              frame_height: 570,
              authenticator: Auth::SalesforceAuthenticator.new('salesforce', trusted: true, auto_create_account: true)
