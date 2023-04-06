# frozen_string_literal: true

module ::Salesforce
  class Case < ::ActiveRecord::Base
    self.table_name = "salesforce_cases"

    belongs_to :topic

    def generate!
      payload = {
        ContactId: self.contact_id,
        Subject: self.subject,
        Description: self.description,
        Origin: SiteSetting.salesforce_case_origin,
      }

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
          c.contact_id = user.salesforce_contact_id

          if c.contact_id.blank? && !SiteSetting.salesforce_skip_contact_creation_on_case_sync
            c.contact_id = user.create_salesforce_contact
          end

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
  end
end
