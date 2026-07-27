# frozen_string_literal: true

module ::Salesforce
  class AmbiguousEmailMatch < StandardError
    attr_reader :object_name

    def initialize(object_name)
      @object_name = object_name
      super("Multiple Salesforce #{object_name} records have the same email")
    end
  end

  class Person
    OBJECT_NAME = ""
    ID_FIELD = ""
    FIELD_NAME_PATTERN = /\A[A-Za-z][A-Za-z0-9_]*\z/

    def self.create!(user)
      return if user.custom_fields[self::ID_FIELD].present?

      id = find_id_by_email(user.email)
      id ||= Salesforce::Api.new.post("sobjects/#{self::OBJECT_NAME}", payload(user))["id"]

      user.custom_fields[self::ID_FIELD] = id
      user.save_custom_fields

      group.add(user)

      id
    end

    def self.sync(user)
      mode = SiteSetting.salesforce_existing_record_sync_mode
      sync_payload =
        if mode == "link_only"
          {}
        else
          payload(user).slice(*self::FIELDS_TO_SYNC)
        end

      record =
        find_by_email(user.email, fields: sync_payload.keys, require_unique: sync_payload.present?)
      return false if record.blank?

      user.custom_fields[self::ID_FIELD] = record["Id"]
      user.save_custom_fields

      return true if sync_payload.empty?

      fields =
        sync_payload.each_with_object({}) do |(field, value), result|
          existing_value = record[field.to_s]
          next if value.nil? || (value.respond_to?(:empty?) && value.empty?)
          if mode == "fill_blank"
            next if existing_value.present? || existing_value == false
          end

          result[field] = value
        end
      return true if fields.empty?

      update!(record["Id"], fields)
      true
    end

    def self.find_by_email(email, fields: [], require_unique: false)
      # Keep the default lookup ID-only because create/link callers do not need record data.
      fields = ["Id", *fields.map(&:to_s)].uniq
      invalid_field = fields.find { |field| !FIELD_NAME_PATTERN.match?(field) }
      raise ArgumentError, "Invalid Salesforce field name: #{invalid_field}" if invalid_field

      escaped_email = escape_soql_string(email)
      result =
        Salesforce.api.query(
          "SELECT #{fields.join(",")} FROM #{self::OBJECT_NAME} WHERE Email = '#{escaped_email}'",
        )
      return if result["totalSize"] == 0
      raise AmbiguousEmailMatch.new(self::OBJECT_NAME) if require_unique && result["totalSize"] > 1

      result["records"][0]
    end

    def self.find_id_by_email(email)
      find_by_email(email)&.dig("Id")
    end

    def self.update!(id, fields)
      Salesforce.api.patch("sobjects/#{self::OBJECT_NAME}/#{id}", fields)
    end

    def self.group
      not_implemented
    end

    def self.payload(user)
      not_implemented
    end

    private

    def self.escape_soql_string(value)
      value.to_s.gsub(/['\\]/) { |character| "\\#{character}" }
    end

    def self.not_implemented
      raise "Not implemented."
    end
  end
end
