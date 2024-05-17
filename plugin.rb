# frozen_string_literal: true

# name: discourse-salesforce
# about: Allows synchronization between Discourse Users and Salesforce leads/contacts, and enables Salesforce Social Login.
# meta_topic_id: 218267
# version: 0.1.0
# author: Vinoth Kannan
# url: https://github.com/discourse/discourse-salesforce
# required_version: 2.7.0

require "auth/managed_authenticator"
require "omniauth-oauth2"
require "openssl"
require "base64"

enabled_site_setting :salesforce_enabled

register_asset "stylesheets/salesforce.scss"

register_svg_icon "fab-salesforce"
register_svg_icon "address-card"

require_relative "lib/validators/salesforce_login_enabled_validator"

after_initialize do
  SeedFu.fixture_paths << Rails.root.join("plugins", "discourse-salesforce", "db", "fixtures").to_s

  module ::Salesforce
    PLUGIN_NAME = "discourse-salesforce"

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

    def self.seed_groups!
      if leads_group.blank?
        group =
          Group.where(name: "salesforce-leads").first_or_create!(
            name: "salesforce-leads",
            visibility_level: Group.visibility_levels[:staff],
            primary_group: true,
            bio_raw: "Members are automatically synced from Salesforce via API",
            full_name: "Salesforce Leads",
          )
        SiteSetting.salesforce_leads_group_id = group.id
      end

      if contacts_group.blank?
        group =
          Group.where(name: "salesforce-contacts").first_or_create!(
            name: "salesforce-contacts",
            visibility_level: Group.visibility_levels[:staff],
            primary_group: true,
            bio_raw: "Members are automatically synced from Salesforce via API",
            full_name: "Salesforce Contacts",
          )
        SiteSetting.salesforce_contacts_group_id = group.id
      end
    end
  end

  require_relative "app/controllers/salesforce/admin_controller"
  require_relative "app/controllers/salesforce/cases_controller"
  require_relative "app/controllers/salesforce/persons_controller"
  require_relative "app/jobs/regular/create_case_comment"
  require_relative "app/jobs/regular/create_feed_item"
  require_relative "app/jobs/regular/sync_case_comments"
  require_relative "app/jobs/regular/sync_case"
  require_relative "app/jobs/scheduled/sync_salesforce_users"
  require_relative "app/models/salesforce/case"
  require_relative "app/models/salesforce/feed_item"
  require_relative "app/models/salesforce/case_comment"
  require_relative "app/models/salesforce/person"
  require_relative "app/models/salesforce/lead"
  require_relative "app/models/salesforce/contact"
  require_relative "app/serializers/concerns/case_mixin"
  require_relative "app/serializers/case_serializer"
  require_relative "lib/salesforce/api"
  require_relative "lib/salesforce/user_extension"
  require_relative "lib/salesforce/topic_extension"

  Salesforce::Engine.routes.draw do
    post "/persons/create" => "persons#create"
    post "/cases/sync" => "cases#sync"
    get "/admin/authorize" => "admin#authorize"
  end

  Discourse::Application.routes.append { mount ::Salesforce::Engine, at: "salesforce" }

  AdminDashboardData.problem_messages << ::Salesforce::Api::APP_NOT_APPROVED

  allow_staff_user_custom_field(::Salesforce::Contact::ID_FIELD)
  allow_staff_user_custom_field(::Salesforce::Lead::ID_FIELD)
  register_topic_custom_field_type(::CaseMixin::HAS_SALESFORCE_CASE, :boolean)
  CategoryList.preloaded_topic_custom_fields << ::CaseMixin::HAS_SALESFORCE_CASE
  Search.preloaded_topic_custom_fields << ::CaseMixin::HAS_SALESFORCE_CASE

  on(:user_created) do |user, opts|
    if ::Salesforce::Api.has_credentials?
      if user.salesforce_contact_id = ::Salesforce::Contact.find_id_by_email(user.email)
        user.save_custom_fields
      elsif user.salesforce_lead_id = ::Salesforce::Lead.find_id_by_email(user.email)
        user.save_custom_fields
      end
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
    sync_tags = SiteSetting.salesforce_automatic_case_sync_tags.split("|")

    return if sync_tags.empty?
    return if sync_tags.intersection(topic.tags.pluck(:name)).empty?

    Jobs.enqueue(:sync_case, topic_id: topic.id)
  end

  on(:topic_created, &automatic_case_sync)
  on(:post_edited) { |post| automatic_case_sync.call(post.topic) }

  reloadable_patch do |plugin|
    User.prepend(Salesforce::UserExtension)
    Topic.prepend(Salesforce::TopicExtension)
    TopicListItemSerializer.include(CaseMixin)
    SearchTopicListItemSerializer.include(CaseMixin)
    SuggestedTopicSerializer.include(CaseMixin)
    UserSummarySerializer::TopicSerializer.include(CaseMixin)
    ListableTopicSerializer.include(CaseMixin)
  end

  add_to_serializer(
    :topic_view,
    :salesforce_case,
    include_condition: -> do
      SiteSetting.salesforce_enabled && scope.is_staff? && object.topic.has_salesforce_case
    end,
  ) { ::Salesforce::CaseSerializer.new(object.topic.salesforce_case, root: false).as_json }

  TopicList.preloaded_custom_fields << "has_salesforce_case"

  class ::OmniAuth::Strategies::Salesforce
    option :name, "salesforce"

    option :client_options,
           authorize_url: "/services/oauth2/authorize",
           token_url: "/services/oauth2/token"
  end
end

#
# Class is mostly cut and paste from MIT https://raw.githubusercontent.com/realdoug/omniauth-salesforce/master/lib/omniauth/strategies/salesforce.rb
class OmniAuth::Strategies::Salesforce < OmniAuth::Strategies::OAuth2
  MOBILE_USER_AGENTS = "webos|ipod|iphone|ipad|android|blackberry|mobile"

  option :authorize_options, %i[scope display immediate state prompt redirect_uri login_hint]

  def request_phase
    req = Rack::Request.new(@env)
    options.update(req.params)
    ua = req.user_agent.to_s
    if !options.has_key?(:display)
      mobile_request = ua.downcase =~ Regexp.new(MOBILE_USER_AGENTS)
      options[:display] = mobile_request ? "touch" : "page"
    end
    super
  end

  def auth_hash
    signed_value = access_token.params["id"] + access_token.params["issued_at"]
    raw_expected_signature =
      OpenSSL::HMAC.digest("sha256", options.client_secret.to_s, signed_value)
    expected_signature = Base64.strict_encode64 raw_expected_signature
    signature = access_token.params["signature"]
    fail! "Salesforce user id did not match signature!" unless signature == expected_signature
    super
  end

  uid { raw_info["id"] }

  info do
    {
      name: raw_info["display_name"],
      email: raw_info["email"],
      nickname: raw_info["nick_name"],
      first_name: raw_info["first_name"],
      last_name: raw_info["last_name"],
      location: "",
      description: "",
      image: raw_info["photos"]["thumbnail"] + "?oauth_token=#{access_token.token}",
      phone: "",
      urls: raw_info["urls"],
    }
  end

  credentials do
    hash = { token: access_token.token, instance_url: access_token.params["instance_url"] }
    hash.merge!(refresh_token: access_token.refresh_token) if access_token.refresh_token
    hash
  end

  def raw_info
    access_token.options[:mode] = :header
    @raw_info ||= access_token.post(access_token["id"]).parsed
  end

  extra do
    raw_info.merge(
      {
        "instance_url" => access_token.params["instance_url"],
        "pod" => access_token.params["instance_url"],
        "signature" => access_token.params["signature"],
        "issued_at" => access_token.params["issued_at"],
      },
    )
  end
end

class Auth::SalesforceAuthenticator < Auth::ManagedAuthenticator
  def name
    "salesforce"
  end

  def register_middleware(omniauth)
    omniauth.provider :salesforce,
                      setup:
                        lambda { |env|
                          strategy = env["omniauth.strategy"]
                          strategy.options[:client_id] = SiteSetting.salesforce_client_id
                          strategy.options[:client_secret] = SiteSetting.salesforce_client_secret
                          strategy.options[
                            :redirect_uri
                          ] = "#{Discourse.base_url}/auth/salesforce/callback"
                          strategy.options[:client_options][
                            :site
                          ] = SiteSetting.salesforce_authorization_server_url
                        }
  end

  def enabled?
    SiteSetting.salesforce_login_enabled
  end

  # salesforce doesn't return unverified emails in their API so we can assume
  # the email we get from them is verified
  def primary_email_verified?(auth_token)
    true
  end
end

auth_provider icon: "fab-salesforce",
              frame_width: 840,
              frame_height: 570,
              authenticator: Auth::SalesforceAuthenticator.new
