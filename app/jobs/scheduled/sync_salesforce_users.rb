# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUsers < ::Jobs::Scheduled
    every 12.hours
    sidekiq_options retry: false

    def execute(args)
      return unless SiteSetting.salesforce_enabled

      begin
        api_client = Salesforce::Api.new
      rescue Salesforce::InvalidCredentials
        return
      end

      if ::Salesforce.leads_enabled?
        lead_fields = UserCustomField.where(name: ::Salesforce::Lead::ID_FIELD)
        lead_fields.find_in_batches(batch_size: 100) do |fields|
          ids = fields.pluck(:value)
          begin
            data =
              api_client.get(
                "composite/sobjects/Lead?fields=ConvertedContactId&ids=#{ids.join(",")}",
              )
            data.each do |lead|
              next if lead.nil?

              contact_id = lead["ConvertedContactId"]
              next if contact_id.blank?

              field = lead_fields.find_by(value: lead["Id"])
              reconcile_link(field, "Lead", lead["Id"], "Contact", contact_id)
            end
          rescue => e
            Discourse.warn_exception(e, message: "Failed to sync Salesforce leads")
          end
        end
      end

      contact_fields = UserCustomField.where(name: ::Salesforce::Contact::ID_FIELD)
      contact_fields.find_in_batches(batch_size: 100) do |fields|
        ids = fields.pluck(:value)
        begin
          data =
            api_client.get("composite/sobjects/Contact?fields=MasterRecordId&ids=#{ids.join(",")}")
          data.each do |contact|
            next if contact.nil?

            new_contact_id = contact["MasterRecordId"]
            next if new_contact_id.blank?

            field = contact_fields.find_by(value: contact["Id"])
            reconcile_link(field, "Contact", contact["Id"], "Contact", new_contact_id)
          end
        rescue => e
          Discourse.warn_exception(e, message: "Failed to sync Salesforce contacts")
        end
      end
    end

    private

    def reconcile_link(field, object, previous_id, destination_object, id)
      return unless field
      DistributedMutex.synchronize("salesforce_person_create_#{field.user_id}") do
        UserCustomField.transaction do
          current = UserCustomField.lock.find_by(id: field.id)
          unless current && current.name == Salesforce::Person.for_object(object)::ID_FIELD &&
                   current.value == previous_id
            next
          end
          destination_name = Salesforce::Person.for_object(destination_object)::ID_FIELD
          destination = UserCustomField.find_by(user_id: current.user_id, name: destination_name)
          if destination && destination.id != current.id
            destination.update!(value: id)
            current.destroy!
          else
            current.update!(name: destination_name, value: id)
          end
          scope = {
            provider: "salesforce",
            account: SiteSetting.salesforce_instance_url,
            user_id: field.user_id,
          }
          previous = Salesforce::RecordLink.new(**scope, object: object).read
          if previous && previous["account"] == scope[:account] && previous["id"] == previous_id
            Salesforce::RecordLink.new(**scope, object: destination_object).write(id)
          end
        end
      end
    end
  end
end
