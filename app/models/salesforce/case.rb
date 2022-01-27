# frozen_string_literal: true

module ::Salesforce

  class Case < ::ActiveRecord::Base
    self.table_name = "salesforce_cases"

    def create!
      payload = {
        ContactId: self.contact_id,
        Subject: self.subject,
        Description: self.description
      }

      data = Salesforce::Api.new.post("sobjects/case", payload)

      self.uid = data["id"]
      save!
      sync!
    end

    def sync!
    end

    CASE_ID_FIELD = "salesforce_case_id"

    def self.sync!(topic)
      find_or_initialize_by(topic_id: topic.id).tap do |c|
        if c.new_record?
          c.subject = topic.title
          c.description = topic.first_post.raw
          c.create!
        else
          c.sync!
        end
      end
    end
  end
end
