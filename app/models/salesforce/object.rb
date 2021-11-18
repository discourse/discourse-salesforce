# frozen_string_literal: true

module ::Salesforce
  class Object
    DEFAULT_COMPANY_NAME = "None".freeze
    ORIGIN = "Web".freeze

    attr_reader :type, :custom_field_name, :api_path, :opts

    def initialize(type, opts: {})
      @type = type
      @custom_field_name = "salesforce_#{type}_id"
      @api_path = "sobjects/#{type.capitalize}"
      @opts = opts
    end

    def self.create!(payload)
      return if exists?

      payload = {}
      payload.merge!(user_payload) if opts[:include_user_payload]

      yield(payload)

      data = Salesforce::Api.new.post(api_path, payload)

      user.custom_fields[custom_field_name] = data["id"]
      user.save_custom_fields
    end

    def exists?
      user.custom_fields[custom_field_name].present?
    end

    def user_payload
      payload = {}
      user = opts[:user]
      name = user.name || user.username

      if name.include?(" ")
        first_name, last_name = name.split(" ", 2)
      else
        last_name = name
      end

      payload = {
        Email: user.email,
        LastName: last_name
      }

      payload.merge!(FirstName: first_name) if first_name.present?
      payload
    end
  end
end
