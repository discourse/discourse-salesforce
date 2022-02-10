# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUsers < ::Jobs::Scheduled
    every 12.hours
    sidekiq_options retry: false

    def execute(args)
      return unless SiteSetting.salesforce_enabled && SiteSetting.salesforce_access_token && SiteSetting.salesforce_instance_url

      lead_fields = UserCustomField.where(name: ::Salesforce::Person::LEAD_ID_FIELD)
      lead_fields.find_in_batches(batch_size: 100) do |fields|
        ids = fields.pluck(:value)
        data = Salesforce::Api.new.get("composite/sobjects/Lead?fields=ConvertedContactId&ids=#{ids.join(",")}")
        data.each do |lead|
          next if lead["ConvertedContactId"].blank?
          lead_fields.where(value: lead["Id"]).update_all(value: lead["ConvertedContactId"], name: ::Salesforce::Person::CONTACT_ID_FIELD)
        end
      end

      contact_fields = UserCustomField.where(name: ::Salesforce::Person::CONTACT_ID_FIELD)
      contact_fields.find_in_batches(batch_size: 100) do |fields|
        ids = fields.pluck(:value)
        data = Salesforce::Api.new.get("composite/sobjects/Contact?fields=MasterRecordId&ids=#{ids.join(",")}")
        data.each do |contact|
          next if contact["MasterRecordId"].blank?
          contact_fields.where(value: contact["Id"]).update_all(value: contact["MasterRecordId"])
        end
      end
    end
  end
end
