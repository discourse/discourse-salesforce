# frozen_string_literal: true

module Salesforce
  class ConfiguredUserSync
    SOURCE_TYPES = {
      "first" => "text",
      "last" => "text",
      "profile" => "text",
      "company" => "text",
      "posts" => "number",
      "posts30" => "number",
      "trust" => "number",
      "groups" => "text",
      "seen" => "date",
      "source" => "text",
    }.freeze

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
      destinations = mappings.map { |mapping| mapping["destination"] }
      valid = destinations.uniq.size == destinations.size && !destinations.include?("Email")
      valid &&= destinations.include?("LastName")
      valid &&= destinations.include?("Company") if configuration["object"] == "Lead"
      valid &&= fields.any? { |field| field["name"] == "Email" && field["createable"] }
      valid &&=
        mappings.all? do |mapping|
          field = fields.find { |item| item["name"] == mapping["destination"] }
          field && SOURCE_TYPES[mapping["source"]].present? &&
            SOURCE_TYPES[mapping["source"]] == field_type(field["type"]) &&
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
        return unless GroupUser.exists?(group_id: configuration["group_id"], user_id: user.id)
        new(configuration, user).sync
      end
    end

    def initialize(configuration, user)
      @configuration = configuration
      @user = user
      @person = configuration["object"] == "Lead" ? Lead : Contact
      @api = Api.new
    end

    def sync
      if @configuration["instance_url"] != SiteSetting.salesforce_instance_url
        raise Discourse::InvalidParameters.new(:salesforce_instance_url)
      end
      fields = @api.writable_fields(@configuration["object"])
      self.class.validate_mappings!(@configuration, fields)
      link_key = "configured_user_link:#{@configuration["object"]}:#{@user.id}"
      link = PluginStore.get(PLUGIN_NAME, link_key)
      if link && link["instance"] != SiteSetting.salesforce_instance_url
        raise Discourse::InvalidParameters.new(:salesforce_instance_url)
      end
      record =
        if link
          @api.get("sobjects/#{@configuration["object"]}/#{link.fetch("id")}")
        else
          @person.find_by_email(
            @user.email,
            fields: @configuration["mappings"].map { |mapping| mapping["destination"] },
            require_unique: true,
            api: @api,
          )
        end
      values = payload(fields, record)
      if record
        id = record.fetch("Id")
        PluginStore.set(
          PLUGIN_NAME,
          link_key,
          { id: id, instance: SiteSetting.salesforce_instance_url },
        )
        @api.patch("sobjects/#{@configuration["object"]}/#{id}", values) if values.present?
      else
        id =
          @api.post(
            "sobjects/#{@configuration["object"]}",
            values.merge("Email" => @user.email),
          ).fetch("id")
        PluginStore.set(
          PLUGIN_NAME,
          link_key,
          { id: id, instance: SiteSetting.salesforce_instance_url },
        )
      end
      @user.custom_fields[@person::ID_FIELD] = id
      @user.save_custom_fields
      GuidedSyncConfiguration.record_result(@configuration["id"], @user.id)
    end

    private

    def payload(fields, record)
      @configuration["mappings"].each_with_object({}) do |mapping, result|
        destination = mapping["destination"]
        field = fields.find { |item| item["name"] == destination }
        next unless field[record ? "updateable" : "createable"]
        existing = record && record[destination]
        next if record && mapping["policy"] == "keep" && !existing.nil? && existing != ""
        value = source_value(mapping["source"])
        next if value.nil? || value == ""
        value = value.to_date.iso8601 if field["type"] == "date"
        value = value.utc.iso8601 if field["type"] == "datetime"
        next if existing == value
        result[destination] = value
      end
    end

    def source_value(source)
      case source
      when "first"
        @user.salesforce_contact_payload[:FirstName]
      when "last"
        @user.salesforce_contact_payload[:LastName]
      when "profile"
        "#{Discourse.base_url}/u/#{UrlHelper.encode_component(@user.username)}"
      when "company"
        field = UserField.where("lower(name) = ?", "company").first
        (field && @user.user_fields&.[](field.id.to_s)).presence || Lead::DEFAULT_COMPANY_NAME
      when "posts"
        @user.user_stat&.post_count || 0
      when "posts30"
        Post
          .joins(:topic)
          .where(topics: { archetype: Archetype.default })
          .where(user_id: @user.id, post_type: Post.types[:regular])
          .where("posts.created_at >= ?", 30.days.ago)
          .count
      when "trust"
        @user.trust_level
      when "groups"
        @user.groups.order(:name).pluck(:name).join(", ")
      when "seen"
        @user.last_seen_at
      when "source"
        "Community"
      end
    end
  end
end
