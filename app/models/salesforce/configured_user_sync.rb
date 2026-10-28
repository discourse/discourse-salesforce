# frozen_string_literal: true

module Salesforce
  class ConfiguredUserSync
    def self.field_type(type)
      return "number" if %w[int double currency percent].include?(type)
      return "date" if %w[date datetime].include?(type)
      if %w[
           string
           textarea
           email
           phone
           url
           picklist
           multipicklist
           combobox
           encryptedstring
         ].include?(type)
        return "text"
      end
      type
    end

    def self.validate_mappings!(configuration, fields)
      mappings = configuration["mappings"]
      unless mappings.is_a?(Array) && mappings.all? { |mapping| mapping.is_a?(Hash) }
        raise Discourse::InvalidParameters.new(:mappings)
      end
      source_types =
        UserSyncSources::SOURCE_TYPES.merge(
          UserSyncSources.custom_sources.to_h { |source| [source[:id], source[:type]] },
        )
      destinations = mappings.map { |mapping| mapping["destination"] }
      valid = destinations.uniq.size == destinations.size && !destinations.include?("Email")
      person = Person.for_object(configuration["object"])
      valid &&= (person::REQUIRED_MAPPING_FIELDS - destinations).empty?
      valid &&= fields.any? { |field| field["name"] == "Email" && field["createable"] }
      valid &&=
        mappings.all? do |mapping|
          field = fields.find { |item| item["name"] == mapping["destination"] }
          static_value_valid =
            mapping["source"] != "static" ||
              (
                mapping["value"].is_a?(String) && mapping["value"].present? &&
                  mapping["value"].length <= 1000
              )
          static_value_valid && field && source_types[mapping["source"]].present? &&
            source_types[mapping["source"]] == field_type(field["type"]) &&
            %w[keep overwrite].include?(mapping["policy"])
        end
      raise Discourse::InvalidParameters.new(:mappings) unless valid
    end

    def self.sync(configuration_id, user_id, reason: nil)
      return unless GuidedSyncConfiguration.enabled?
      DistributedMutex.synchronize("salesforce_person_create_#{user_id}") do
        configuration =
          GuidedSyncConfiguration.active.find { |item| item["id"] == configuration_id }
        unless configuration && GuidedSyncConfiguration.reason_enabled?(configuration, reason)
          return
        end
        user = User.find_by(id: user_id)
        return unless user && Person.auto_create_eligible?(user)
        unless GroupUser.exists?(
                 group_id: Salesforce::GuidedSyncConfiguration.group_ids(configuration),
                 user_id: user.id,
               )
          return
        end
        new(configuration, user).sync(skip_unchanged: reason == "change")
      end
    end

    def initialize(configuration, user, api: nil, source_data: nil)
      @configuration = configuration
      @user = user
      @person = Person.for_object(configuration["object"])
      @api = api || Api.new
      @source_data = source_data
    end

    def sync(skip_unchanged: false)
      if @configuration["instance_url"] != SiteSetting.salesforce_instance_url
        raise Discourse::InvalidParameters.new(:salesforce_instance_url)
      end
      fingerprint_key = "configuration_user_fingerprint:#{@configuration["id"]}:#{@user.id}"
      fingerprint = source_fingerprint
      return if skip_unchanged && PluginStore.get(PLUGIN_NAME, fingerprint_key) == fingerprint
      fields = @api.writable_fields(@configuration["object"])
      self.class.validate_mappings!(@configuration, fields)
      record = existing_record
      values = mapped_values(fields, record)
      if record
        id = record.fetch("Id")
        save_link(id)
        @api.patch("sobjects/#{@configuration["object"]}/#{id}", values) if values.present?
      else
        id =
          @api.post(
            "sobjects/#{@configuration["object"]}",
            values.merge("Email" => @user.email),
          ).fetch("id")
      end
      complete(id)
      PluginStore.set(PLUGIN_NAME, fingerprint_key, fingerprint)
    end

    def complete(id)
      save_link(id)
      @user.custom_fields[@person::ID_FIELD] = id
      @user.save_custom_fields
      GuidedSyncConfiguration.record_result(@configuration["id"], @user.id)
    end

    def mapped_values(fields, record)
      FieldMapping
        .new(@configuration["mappings"], fields) { |source, _field| source_value(source) }
        .values(record)
    end

    private

    def save_link(id)
      record_link.write(id)
    end

    def record_link
      @record_link ||=
        RecordLink.new(
          provider: @configuration.fetch("provider", "salesforce"),
          account: @configuration.fetch("instance_url"),
          object: @configuration.fetch("object"),
          user_id: @user.id,
        )
    end

    def source_fingerprint
      sources = @configuration["mappings"].map { |mapping| mapping["source"] }.uniq - ["static"]
      Digest::SHA256.hexdigest(
        {
          instance: SiteSetting.salesforce_instance_url,
          object: @configuration["object"],
          mappings: @configuration["mappings"],
          email: @user.email,
          values: sources.to_h { |source| [source, source_value(source)] },
        }.to_json,
      )
    end

    def existing_record
      link = record_link.read
      if link && link["account"] != SiteSetting.salesforce_instance_url
        raise Discourse::InvalidParameters.new(:salesforce_instance_url)
      end
      record = linked_record(link) if link
      fields = @configuration["mappings"].map { |mapping| mapping["destination"] }
      record ||= @person.find_by_email(@user.email, fields: fields, require_unique: true, api: @api)
    end

    def linked_record(link)
      @api.get("sobjects/#{@configuration["object"]}/#{link.fetch("id")}")
    rescue Salesforce::InvalidApiResponse => error
      raise unless error.status == 404 && @configuration["object"] == "Lead"
      id = link.fetch("id")
      raise unless id.match?(/\A[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?\z/)
      query = "SELECT Id, IsDeleted, IsConverted FROM Lead WHERE Id = '#{id}'"
      records = @api.get("queryAll/?q=#{CGI.escape(query)}").fetch("records")
      deleted = records.find { |record| record["Id"] == id }
      raise error unless deleted && deleted["IsDeleted"] == true && deleted["IsConverted"] == false
      nil
    end

    def source_value(source)
      @source_data ||= UserSyncSources.new(@configuration["mappings"], [@user])
      FieldMapping.source_value(@source_data, source, @user)
    end
  end
end
