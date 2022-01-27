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
    end

    def sync!
      data = Salesforce::Api.new.get("sobjects/case/#{self.uid}")

      self.number = data["CaseNumber"]
      self.status = data["Status"]
      save!
    end

    CASE_ID_FIELD = "salesforce_case_id"

    def self.sync!(topic)
      find_or_initialize_by(topic_id: topic.id).tap do |c|
        user = topic.user

        if c.new_record?
          c.contact_id = user.salesforce_contact_id || user.create_salesforce_contact
          c.subject = topic.title
          c.description = topic.first_post.raw
          c.create!
        end

        c.sync!
      end
    end
  end
end
