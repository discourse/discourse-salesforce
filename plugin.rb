# frozen_string_literal: true

# name: discourse-salesforce
# about: Integration features between Salesforce and Discourse
# version: 0.1.0
# author: Vinoth Kannan
# url: https://github.com/discourse/discourse-salesforce
# required_version: 2.7.0
# transpile_js: true

require 'auth/managed_authenticator'
require 'omniauth-oauth2'
require 'openssl'
require 'base64'

enabled_site_setting :salesforce_enabled

register_asset 'stylesheets/salesforce.scss'

register_svg_icon "fab-salesforce"
register_svg_icon "address-card"

require_relative 'lib/validators/salesforce_login_enabled_validator'

after_initialize do
  SeedFu.fixture_paths << Rails.root.join("plugins", "discourse-salesforce", "db", "fixtures").to_s

  module ::Salesforce
    PLUGIN_NAME = 'discourse-salesforce'

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace Salesforce
    end

    def self.api
      @api ||= Api.new
    end

    def self.leads_group
      group_id = SiteSetting.salesforce_leads_group_id
      return if group_id.blank?

      Group.find_by(id: group_id)
    end

    def self.contacts_group
      group_id = SiteSetting.salesforce_contacts_group_id
      return if group_id.blank?

      Group.find_by(id: group_id)
    end
  end

  [
    '../app/controllers/salesforce/admin_controller.rb',
    '../app/controllers/salesforce/cases_controller.rb',
    '../app/controllers/salesforce/persons_controller.rb',
    '../app/jobs/regular/create_case_comment.rb',
    '../app/jobs/regular/create_feed_item.rb',
    '../app/jobs/regular/sync_case_comments.rb',
    '../app/jobs/regular/sync_case.rb',
    '../app/jobs/scheduled/sync_salesforce_users.rb',
    '../app/models/salesforce/case.rb',
    '../app/models/salesforce/feed_item.rb',
    '../app/models/salesforce/case_comment.rb',
    '../app/models/salesforce/person.rb',
    '../app/models/salesforce/lead.rb',
    '../app/models/salesforce/contact.rb',
    '../app/serializers/concerns/case_mixin.rb',
    '../app/serializers/case_serializer.rb',
    '../lib/salesforce/api.rb'
  ].each { |path| load File.expand_path(path, __FILE__) }

  Salesforce::Engine.routes.draw do
    post "/persons/create" => "persons#create"
    post "/cases/sync" => "cases#sync"
    get "/admin/authorize" => "admin#authorize"
  end

  Discourse::Application.routes.append do
    mount ::Salesforce::Engine, at: "salesforce"
  end

  AdminDashboardData.problem_messages << ::Salesforce::Api::APP_NOT_APPROVED

  allow_staff_user_custom_field(::Salesforce::Contact::ID_FIELD)
  allow_staff_user_custom_field(::Salesforce::Lead::ID_FIELD)
  register_topic_custom_field_type(::CaseMixin::HAS_SALESFORCE_CASE, :boolean)
  CategoryList.preloaded_topic_custom_fields << ::CaseMixin::HAS_SALESFORCE_CASE
  Search.preloaded_topic_custom_fields << ::CaseMixin::HAS_SALESFORCE_CASE

  on(:user_created) do |user, opts|
    if user.salesforce_contact_id = ::Salesforce::Contact.find_id_by_email(user.email)
      user.save_custom_fields
    elsif user.salesforce_lead_id = ::Salesforce::Lead.find_id_by_email(user.email)
      user.save_custom_fields
    end
  end

  on(:post_created) do |post, opts|
    topic = post.topic

    if topic.has_salesforce_case
      Jobs.enqueue(:create_case_comment, post_id: post.id)
    else
      Jobs.enqueue(:create_feed_item, post_id: post.id)
    end
  end

  automatic_case_sync = ->(topic, *extras) do
    sync_tags = SiteSetting.salesforce_automatic_case_sync_tags.split('|')

    return if sync_tags.empty?
    return if sync_tags.intersection(topic.tags.pluck(:name)).empty?

    Jobs.enqueue(:sync_case, topic_id: topic.id)
  end

  on(:topic_created, &automatic_case_sync)
  on(:post_edited) do |post|
    automatic_case_sync.call(post.topic)
  end

  reloadable_patch do |plugin|

    class ::User
      def salesforce_contact_id
        custom_fields[::Salesforce::Contact::ID_FIELD]
      end

      def salesforce_lead_id
        custom_fields[::Salesforce::Lead::ID_FIELD]
      end

      def salesforce_contact_id=(value)
        custom_fields[::Salesforce::Contact::ID_FIELD] = value
      end

      def salesforce_lead_id=(value)
        custom_fields[::Salesforce::Lead::ID_FIELD] = value
      end

      def create_salesforce_contact
        ::Salesforce::Contact.create!(self)
      end

      def salesforce_contact_payload
        name = self.name || self.username

        if name.include?(" ")
          first_name, last_name = name.split(" ", 2)
        else
          last_name = name
        end

        payload = {
          Email: self.email,
          LastName: last_name,
          LeadSource: ::Salesforce::Contact::SOURCE,
          Description: "#{Discourse.base_url}/u/#{UrlHelper.encode_component(self.username)}"
        }

        payload.merge!(FirstName: first_name) if first_name.present?

        payload
      end

      def salesforce_lead_payload
        salesforce_contact_payload.merge({
          Company: ::Salesforce::Lead::DEFAULT_COMPANY_NAME,
          Website: self.user_profile&.website
        })
      end
    end

    class ::Topic
      def has_salesforce_case
        custom_fields["has_salesforce_case"] ? true : false
      end

      def salesforce_case
        return unless has_salesforce_case
        ::Salesforce::Case.find_by(topic_id: id)
      end
    end

    class ::TopicListItemSerializer
      include CaseMixin
    end

    class ::SearchTopicListItemSerializer
      include CaseMixin
    end

    class ::SuggestedTopicSerializer
      include CaseMixin
    end

    class ::UserSummarySerializer::TopicSerializer
      include CaseMixin
    end

    class ::ListableTopicSerializer
      include CaseMixin
    end

    class ::TopicViewSerializer
      attributes :salesforce_case

      def include_salesforce_case?
        SiteSetting.salesforce_enabled && scope.is_staff? && object.topic.has_salesforce_case
      end

      def salesforce_case
        ::Salesforce::CaseSerializer.new(object.topic.salesforce_case, root: false).as_json
      end
    end
  end

  TopicList.preloaded_custom_fields << "has_salesforce_case"

  class ::OmniAuth::Strategies::Salesforce
    option :name, 'salesforce'

    option :client_options,
            authorize_url: '/services/oauth2/authorize',
            token_url: '/services/oauth2/token'
  end
end

#
# Class is mostly cut and paste from MIT https://raw.githubusercontent.com/realdoug/omniauth-salesforce/master/lib/omniauth/strategies/salesforce.rb
class OmniAuth::Strategies::Salesforce < OmniAuth::Strategies::OAuth2

  MOBILE_USER_AGENTS = 'webos|ipod|iphone|ipad|android|blackberry|mobile'

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
      name: raw_info['display_name'],
      email: raw_info['email'],
      nickname: raw_info['nick_name'],
      first_name: raw_info['first_name'],
      last_name: raw_info['last_name'],
      location: '',
      description: '',
      image: raw_info['photos']['thumbnail'] + "?oauth_token=#{access_token.token}",
      phone: '',
      urls: raw_info['urls']
    }
  end

  credentials do
    hash = { token: access_token.token, instance_url: access_token.params["instance_url"] }
    hash.merge!(refresh_token: access_token.refresh_token) if access_token.refresh_token
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

class Auth::SalesforceAuthenticator < Auth::ManagedAuthenticator
  def name
    "salesforce"
  end

  def register_middleware(omniauth)
    omniauth.provider :salesforce,
                      setup: lambda { |env|
                        strategy = env['omniauth.strategy']
                        strategy.options[:client_id] = SiteSetting.salesforce_client_id
                        strategy.options[:client_secret] = SiteSetting.salesforce_client_secret
                        strategy.options[:redirect_uri] = "#{Discourse.base_url}/auth/salesforce/callback"
                        strategy.options[:client_options][:site] = SiteSetting.salesforce_authorization_server_url
                      }
  end

  def enabled?
    SiteSetting.salesforce_login_enabled
  end

  # salesforce doesn't return unverfied emails in their API so we can assume
  # the email we get from them is verified
  def primary_email_verified?(auth_token)
    true
  end
end

auth_provider icon: 'fab-salesforce',
              frame_width: 840,
              frame_height: 570,
              authenticator: Auth::SalesforceAuthenticator.new
