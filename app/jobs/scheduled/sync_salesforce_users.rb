# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUsers < ::Jobs::Scheduled
    every 12.hours
    sidekiq_options retry: false

    def execute(args)
      return unless SiteSetting.salesforce_enabled

      lead_fields = UserCustomField.where(name: ::Salesforce::Person::LEAD_ID_FIELD)
      lead_fields.find_in_batches(batch_size: 100) do |fields|
        ids = fields.pluck(:value)
        data = Salesforce::Api.new.get("composite/sobjects/Lead?fields=ConvertedContactId&ids=#{ids.join(",")}")
        data.each do |lead|
          contact_id = lead["ConvertedContactId"]
          next if contact_id.blank?

          field = lead_fields.find_by(value: lead["Id"])
          field.update(name: ::Salesforce::Person::CONTACT_ID_FIELD, value: contact_id)
        end
      end

      contact_fields = UserCustomField.where(name: ::Salesforce::Person::CONTACT_ID_FIELD)
      contact_fields.find_in_batches(batch_size: 100) do |fields|
        ids = fields.pluck(:value)
        data = Salesforce::Api.new.get("composite/sobjects/Contact?fields=MasterRecordId&ids=#{ids.join(",")}")
        data.each do |contact|
          new_contact_id = contact["MasterRecordId"]
          next if new_contact_id.blank?

          field = contact_fields.find_by(value: contact["Id"])
          field.update(value: new_contact_id)
        end
      end
    end
  end
end
