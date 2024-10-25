# frozen_string_literal: true

module ::Salesforce
  class Case < ::ActiveRecord::Base
    self.table_name = "salesforce_cases"

    belongs_to :topic

    def generate!
      data = Salesforce::Api.new.post("sobjects/Case", payload)

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
