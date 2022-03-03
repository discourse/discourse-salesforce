# frozen_string_literal: true

module ::Salesforce

  class Case < ::ActiveRecord::Base
    self.table_name = "salesforce_cases"

    belongs_to :topic

    def create!
      payload = {
        ContactId: self.contact_id,
        Subject: self.subject,
        Description: self.description,
        Origin: "Web"
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
        tags << SiteSetting.salesforce_case_tag_name if SiteSetting.salesforce_case_tag_name.present?
        tags << "#{SiteSetting.salesforce_case_status_tag_prefix}-#{self.status.downcase}" if SiteSetting.salesforce_case_status_tag_enabled
        DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), tags)
      end

      MessageBus.publish("/topic/#{topic_id}", reload_topic: true)
    end

    CASE_ID_FIELD = "salesforce_case_id"

    def self.sync!(topic)
      _case = find_or_initialize_by(topic_id: topic.id)
      _case.tap do |c|
        user = topic.user

        if c.new_record?
          post = topic.first_post
          description = "#{post.full_url}\n\n#{post.raw}"
          c.contact_id = user.salesforce_contact_id || user.create_salesforce_contact
          c.subject = topic.title
          c.description = description
          c.create!

          Jobs.enqueue(:sync_case_comments, topic_id: topic.id)

          topic.custom_fields["has_salesforce_case"] = true
          topic.save_custom_fields
        end

        c.sync!
      end
      _case
    end
  end
end
