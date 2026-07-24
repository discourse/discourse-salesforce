# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUser < ::Jobs::Base
    FIELDS_TO_FILL = %i[LeadSource Description]

    def execute(args)
      return unless SiteSetting.salesforce_enabled

      user = User.find(args[:user_id])
      begin
        sync(user, ::Salesforce::Contact) || sync(user, ::Salesforce::Lead)
      rescue Salesforce::InvalidCredentials
      end
    end

    private

    def sync(user, person_type)
      payload = {}
      if SiteSetting.salesforce_fill_blank_fields_on_user_sync
        payload =
          DiscoursePluginRegistry.apply_modifier(
            :salesforce_existing_user_sync_payload,
            person_type.payload(user).slice(*FIELDS_TO_FILL),
            user,
            person_type::OBJECT_NAME,
          )
      end

      record = person_type.find_by_email(user.email, fields: payload.keys)
      return false if record.blank?

      user.custom_fields[person_type::ID_FIELD] = record["Id"]
      user.save_custom_fields

      return true if payload.empty?

      fields =
        payload.each_with_object({}) do |(field, value), result|
          existing_value = record[field.to_s]
          next if value.nil? || (value.respond_to?(:empty?) && value.empty?)
          next if existing_value.present? || existing_value == false

          result[field] = value
        end
      return true if fields.empty?

      person_type.update!(record["Id"], fields)
      true
    end
  end
end
