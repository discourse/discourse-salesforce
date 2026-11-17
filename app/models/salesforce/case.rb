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
          existing_tag_names = topic.tags.pluck(:name)
          if SiteSetting.salesforce_case_status_tag_enabled
            existing_tag_names.reject! do |tag_name|
              tag_name.start_with?("#{SiteSetting.salesforce_case_status_tag_prefix}-")
            end
          end

          tag_names = (existing_tag_names + tags).uniq
          if tag_names.size <= SiteSetting.max_tags_per_topic
            DiscourseTagging.tag_topic_by_names(
              topic,
              Guardian.new(Discourse.system_user),
              tag_names,
            )
          end
        end
      end

      MessageBus.publish("/topic/#{topic_id}", reload_topic: true)
    end

    def unlink!
      with_lock do
        PostCustomField.where(
          post_id: Post.where(topic_id: topic_id).select(:id),
          name: CaseComment::ID_FIELD,
        ).delete_all
        TopicCustomField.where(
          topic_id: topic_id,
          name: ::CaseMixin::HAS_SALESFORCE_CASE,
        ).delete_all

        trigger_tags = SiteSetting.salesforce_automatic_case_sync_tags.split("|")
        old_tag_names = topic.tags.pluck(:name)
        removed_tag_names =
          old_tag_names.select do |name|
            name == SiteSetting.salesforce_case_tag_name || trigger_tags.include?(name) ||
              (
                SiteSetting.salesforce_case_status_tag_enabled &&
                  name.start_with?("#{SiteSetting.salesforce_case_status_tag_prefix}-")
              )
          end
        if removed_tag_names.present?
          topic.tags = topic.tags.where.not(name: removed_tag_names)
          topic.tags_changed = true
          DiscourseEvent.trigger(
            :topic_tags_changed,
            topic,
            old_tag_names: old_tag_names,
            new_tag_names: topic.tags.map(&:name),
            user: Discourse.system_user,
          )
        end

        destroy!
      end

      MessageBus.publish("/topic/#{topic_id}", reload_topic: true)
    end

    CASE_ID_FIELD = "salesforce_case_id"

    def self.sync!(topic, acting_user: nil)
      salesforce_case = find_or_initialize_by(topic_id: topic.id)
      return salesforce_case.tap(&:sync!) if salesforce_case.persisted?

      post = topic.first_post
      description = "#{post.full_url}\n\n#{PostContent.body_for(post, max_length: 30_000)}"
      salesforce_case.contact_id =
        contact_id_for(topic.user, acting_user: acting_user) ||
          SiteSetting.salesforce_default_contact_id_for_case_sync.presence
      salesforce_case.subject = topic.title
      salesforce_case.description = description
      salesforce_case.generate!

      begin
        Jobs.enqueue(:sync_case_comments, topic_id: topic.id)

        topic.custom_fields["has_salesforce_case"] = true
        topic.save_custom_fields

        salesforce_case.sync!
      ensure
        DiscourseEvent.trigger(:salesforce_case_created, salesforce_case, acting_user: acting_user)
      end

      salesforce_case
    end

    def self.contact_id_for(user, acting_user: nil)
      return user.salesforce_contact_id if user.salesforce_contact_id

      if SiteSetting.salesforce_skip_contact_creation_on_case_sync
        nil
      else
        Contact.create!(user, acting_user: acting_user)
      end
    end

    private

    def payload
      default = { ContactId: self.contact_id, Subject: self.subject, Description: self.description }
      origin = SiteSetting.salesforce_case_origin
      default[:Origin] = origin if origin.present?

      DiscoursePluginRegistry.apply_modifier(:salesforce_case_payload, default, topic)
    end
  end
end

# == Schema Information
#
# Table name: salesforce_cases
#
#  id             :bigint           not null, primary key
#  description    :string
#  last_synced_at :datetime
#  number         :string
#  status         :string
#  subject        :string
#  uid            :string
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  contact_id     :string
#  topic_id       :integer          not null
#
# Indexes
#
#  index_salesforce_cases_on_uid  (uid)
#
