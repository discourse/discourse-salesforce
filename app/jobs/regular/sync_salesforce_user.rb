# frozen_string_literal: true

module ::Jobs
  class SyncSalesforceUser < ::Jobs::Base
    FIELDS_TO_FILL = %i[LeadSource Description]

    def execute(args)
      return unless SiteSetting.salesforce_enabled

      user = User.find(args[:user_id])
      begin
        sync(user, ::Salesforce::Contact) || sync(user, ::Salesforce::Lead)
      rescue Salesforce::AmbiguousEmailMatch => error
        Rails.logger.warn(
          "Skipping Salesforce sync for Discourse user #{user.id}: multiple #{error.object_name} records have the same email",
        )
      rescue Salesforce::InvalidCredentials
      end
    end

    private

    def sync(user, person_type)
      mode = SiteSetting.salesforce_existing_record_sync_mode
      payload = {}
      if mode != "disabled"
        payload =
          DiscoursePluginRegistry.apply_modifier(
            :salesforce_existing_user_sync_payload,
            person_type.payload(user).slice(*FIELDS_TO_FILL),
            user,
            person_type::OBJECT_NAME,
          )
      end

      record =
        person_type.find_by_email(
          user.email,
          fields: payload.keys,
          require_unique: mode != "disabled",
        )
      return false if record.blank?

      user.custom_fields[person_type::ID_FIELD] = record["Id"]
      user.save_custom_fields

      return true if payload.empty?

      fields =
        payload.each_with_object({}) do |(field, value), result|
          existing_value = record[field.to_s]
          next if value.nil? || (value.respond_to?(:empty?) && value.empty?)
          if mode == "fill_blank"
            next if existing_value.present? || existing_value == false
          end

          result[field] = value
        end
      return true if fields.empty?

      person_type.update!(record["Id"], fields)
      true
    end
  end
end
