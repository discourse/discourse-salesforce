# frozen_string_literal: true

module ::Salesforce
  class Person
    OBJECT_NAME = ""
    ID_FIELD = ""

    def self.create!(user)
      return if user.custom_fields[self::ID_FIELD].present?

      data = Salesforce::Api.new.post("sobjects/#{self::OBJECT_NAME}", payload(user))
      id = data["id"]

      user.custom_fields[self::ID_FIELD] = id
      user.save_custom_fields

      group.add(user)

      id
    end

    def self.find_id_by_email(email)
      result = Salesforce.api.query("SELECT Id FROM #{self::OBJECT_NAME} WHERE Email = '#{email}'")
      return if result["totalSize"] == 0
      result["records"][0]["Id"]
    end

    def self.group
      not_implemented
    end

    def self.payload(user)
      not_implemented
    end

    private

    def self.not_implemented
      raise "Not implemented."
    end
  end
end
