# frozen_string_literal: true

module Salesforce
  class GuidedSyncConfiguration
    STORE_KEY = "guided_sync_configurations"

    def self.all
      (PluginStore.get(PLUGIN_NAME, STORE_KEY) || []).map do |record|
        record.except("workflows", "onJoin", "onChange").reverse_merge("provider" => "salesforce")
      end
    end

    def self.group_ids(record)
      Array(record["group_ids"] || record["group_id"])
    end

    def self.group_names(record)
      Array(record["groups"] || record["group"]).reject(&:blank?)
    end

    def self.resolve_groups!(names)
      unless names.is_a?(Array) && names.present? && names.size <= 100 &&
               names.all? { |name| name.is_a?(String) && name.present? }
        raise Discourse::InvalidParameters.new(:groups)
      end
      groups = Group.where.not(id: Group::AUTO_GROUPS[:everyone]).where(name: names.uniq)
      raise Discourse::InvalidParameters.new(:groups) if groups.count != names.uniq.size
      groups
    end

    def self.available_groups
      counts = GroupUser.where(user_id: Person.eligible_users.select(:id)).group(:group_id).count
      Group
        .where.not(id: Group::AUTO_GROUPS[:everyone])
        .order(:name)
        .pluck(:id, :name)
        .map { |id, name| { name: name, user_count: counts.fetch(id, 0) } }
    end

    def self.enabled?
      SiteSetting.salesforce_enabled && SiteSetting.enable_guided_sync_configuration
    end

    def self.active
      return [] unless enabled?
      all.select do |record|
        record["active"] && record["kind"] == "users" && record["provider"] == "salesforce"
      end
    end

    def self.reason_enabled?(record, reason)
      case reason
      when "join", "change"
        true
      when "backfill"
        record["backfill"]
      when "scheduled"
        record["schedule"] != "manual"
      else
        false
      end
    end

    def self.record_result(id, user_id, error: nil)
      DistributedMutex.synchronize("salesforce_configuration_status_#{id}") do
        key = "configuration_status:#{id}"
        status = PluginStore.get(PLUGIN_NAME, key) || {}
        if error
          status.merge!(
            "last_error_at" => Time.now.utc.iso8601,
            "error" => error.class.name,
            "user_id" => user_id,
          )
        else
          status["last_synced_at"] = Time.now.utc.iso8601
          status.except!("last_error_at", "error", "user_id") if status["user_id"] == user_id
        end
        PluginStore.set(PLUGIN_NAME, key, status)
      end
    end

    def self.destroy!(id:, guardian:)
      raise Discourse::InvalidAccess unless guardian.is_admin?

      DistributedMutex.synchronize("salesforce_guided_sync_configurations") do
        records = all
        raise Discourse::NotFound unless records.any? { |record| record["id"] == id }
        PluginStore.set(PLUGIN_NAME, STORE_KEY, records.reject { |record| record["id"] == id })
      end
    end

    def self.save!(configuration, id:, guardian:)
      raise Discourse::InvalidAccess unless guardian.is_admin?

      configuration = configuration.deep_stringify_keys
      configuration["kind"] ||= "users"
      configuration["provider"] ||= "salesforce"
      unless configuration["provider"] == "salesforce"
        raise Discourse::InvalidParameters.new(:provider)
      end
      groups = resolve_groups!(group_names(configuration))
      valid_object = %w[Lead Contact].include?(configuration["object"])
      unless configuration["name"].present? && configuration["name"].length <= 60 &&
               configuration["kind"] == "users" && valid_object &&
               %w[daily hourly weekly manual].include?(configuration["schedule"]) &&
               configuration["mappings"].is_a?(Array) && configuration["mappings"].size <= 50
        raise Discourse::InvalidParameters.new(:configuration)
      end

      ConfiguredUserSync.validate_mappings!(
        configuration,
        Api.new.writable_fields(configuration["object"]),
      )
      configuration["groups"] = groups.order(:name).pluck(:name)
      configuration["group_ids"] = groups.order(:name).pluck(:id)
      configuration.delete("group")
      configuration.delete("group_id")

      configuration["backfill"] = ActiveModel::Type::Boolean.new.cast(configuration["backfill"])

      DistributedMutex.synchronize("salesforce_guided_sync_configurations") do
        records = all
        previous = id ? records.find { |record| record["id"] == id } : nil
        raise Discourse::NotFound if id && !previous
        if previous && previous["object"] != configuration["object"]
          raise Discourse::InvalidParameters.new(:object)
        end
        record_id = previous&.dig("id") || SecureRandom.uuid
        record =
          configuration.except("workflows", "onJoin", "onChange").merge(
            "id" => record_id,
            "active" => true,
            "instance_url" => SiteSetting.salesforce_instance_url,
          )
        PluginStore.set(
          PLUGIN_NAME,
          STORE_KEY,
          records.reject { |entry| entry["id"] == record_id } + [record],
        )
        ConfigurationScheduler.configuration_saved(record, previous: previous)
        record
      end
    end
  end
end
