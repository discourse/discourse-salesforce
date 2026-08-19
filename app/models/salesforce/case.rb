# frozen_string_literal: true

module ::Salesforce
  class Case < ::ActiveRecord::Base
    EXTERNAL_ID_FIELD = "Discourse_Topic_Key__c"
    EXTERNAL_ID_CACHE_PREFIX = "salesforce_case_external_id_capability"
    SITE_IDENTIFIER_KEY = "site_identifier"

    self.table_name = "salesforce_cases"

    belongs_to :topic

    def generate!
      api = Salesforce::Api.new
      data =
        if external_id_supported?(api)
          find_or_create_by_external_id(api)
        else
          api.post("sobjects/Case", payload)
        end

      self.uid = data["id"]
      save!
    end

    def sync!
      data = Salesforce::Api.new.get("sobjects/Case/#{self.uid}")

      self.number = data["CaseNumber"]
      self.status = data["Status"]
      self.last_synced_at = Time.zone.now
      save!

      if SiteSetting.tagging_enabled
        topic = Topic.find_by(id: topic_id)
        return if topic.blank?

        tags = []
        if SiteSetting.salesforce_case_tag_name.present?
          tags << SiteSetting.salesforce_case_tag_name
        end
        if SiteSetting.salesforce_case_status_tag_enabled
          tags << "#{SiteSetting.salesforce_case_status_tag_prefix}-#{self.status.downcase}"
        end
        if tags.present?
          DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), tags)
        end
      end

      MessageBus.publish("/topic/#{topic_id}", reload_topic: true)
    end

    CASE_ID_FIELD = "salesforce_case_id"

    def self.external_id_capability_cache_key(instance_url = SiteSetting.salesforce_instance_url)
      "#{EXTERNAL_ID_CACHE_PREFIX}:#{instance_url}"
    end

    def self.site_identifier
      identifier = PluginStore.get(PLUGIN_NAME, SITE_IDENTIFIER_KEY)
      return identifier if identifier.present?

      DistributedMutex.synchronize("salesforce_site_identifier") do
        PluginStore.get(PLUGIN_NAME, SITE_IDENTIFIER_KEY) ||
          SecureRandom.uuid.tap do |new_identifier|
            PluginStore.set(PLUGIN_NAME, SITE_IDENTIFIER_KEY, new_identifier)
          end
      end
    end

    def self.sync!(topic)
      salesforce_case = find_or_initialize_by(topic_id: topic.id)
      salesforce_case.tap do |c|
        user = topic.user

        if c.new_record?
          post = topic.first_post
          description = "#{post.full_url}\n\n#{post.raw}"
          c.contact_id =
            contact_id_for(user) || SiteSetting.salesforce_default_contact_id_for_case_sync.presence
          c.subject = topic.title
          c.description = description
          c.generate!

          Jobs.enqueue(:sync_case_comments, topic_id: topic.id)

          topic.custom_fields["has_salesforce_case"] = true
          topic.save_custom_fields
        end

        c.sync!
      end
      salesforce_case
    end

    def self.contact_id_for(user)
      return user.salesforce_contact_id if user.salesforce_contact_id

      if SiteSetting.salesforce_skip_contact_creation_on_case_sync
        nil
      else
        user.create_salesforce_contact
      end
    end

    private

    def external_id_supported?(api)
      cache_key = self.class.external_id_capability_cache_key
      cached = Discourse.redis.get(cache_key)
      return cached == "1" if cached.present?

      field =
        api
          .get("sobjects/Case/describe")
          .fetch("fields")
          .find { |candidate| candidate["name"] == EXTERNAL_ID_FIELD }
      supported =
        field.present? && field["externalId"] && field["unique"] && field["createable"] &&
          field["updateable"] && field["type"] == "string"

      tracker = ProblemCheckTracker[:salesforce_case_external_id]
      supported ? tracker.no_problem! : tracker.problem!
      Discourse.redis.setex(cache_key, supported ? 10.minutes : 1.minute, supported ? "1" : "0")

      supported
    end

    def find_or_create_by_external_id(api)
      path = "sobjects/Case/#{EXTERNAL_ID_FIELD}/#{external_id_value}"
      existing_case = api.get(path, allow_not_found: true)
      return { "id" => existing_case.fetch("Id") } if existing_case

      api.patch(path, payload.except(EXTERNAL_ID_FIELD, EXTERNAL_ID_FIELD.to_sym))
    end

    def external_id_value
      "#{self.class.site_identifier}-#{topic_id}"
    end

    def payload
      default = {
        ContactId: self.contact_id,
        Subject: self.subject,
        Description: self.description,
        Origin: SiteSetting.salesforce_case_origin,
      }

      DiscoursePluginRegistry.apply_modifier(:salesforce_case_payload, default, topic)
    end
  end
end

# == Schema Information
#
# Table name: salesforce_cases
#
#  id             :bigint           not null, primary key
#  uid            :string
#  topic_id       :integer          not null
#  contact_id     :string
#  number         :string
#  subject        :string
#  description    :string
#  status         :string
#  last_synced_at :datetime
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
# Indexes
#
#  index_salesforce_cases_on_uid  (uid)
#
