# frozen_string_literal: true

module Salesforce
  class GuidedSyncConfiguration
    STORE_KEY = "guided_sync_configurations"

    def self.all
      (PluginStore.get(PLUGIN_NAME, STORE_KEY) || []).map { |record| record.except("workflows") }
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
      SiteSetting.salesforce_enabled && SiteSetting.enable_salesforce_configurations
    end

    def self.active
      return [] unless enabled?
      all.select { |record| record["active"] && record["kind"] == "users" }
    end

    def self.reason_enabled?(record, reason)
      case reason
      when "join"
        record["onJoin"]
      when "change"
        record["onChange"]
      when "backfill"
        record["backfill"]
      when "scheduled"
        record["schedule"] != "manual"
      else
        false
      end
    end

    def self.enqueue_user(user, reason:, group_id: nil, excluding_group_id: nil)
      active.each do |record|
        next unless reason_enabled?(record, reason)
        next if group_id && record["group_id"] != group_id
        next if excluding_group_id && record["group_id"] == excluding_group_id
        next unless GroupUser.exists?(group_id: record["group_id"], user_id: user.id)
        Jobs.enqueue(
          :sync_salesforce_user,
          user_id: user.id,
          configuration_id: record["id"],
          reason: reason,
        )
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
      valid_scope =
        Group.where.not(id: Group::AUTO_GROUPS[:everyone]).exists?(name: configuration["group"])
      valid_object = %w[Lead Contact].include?(configuration["object"])
      unless configuration["name"].present? && configuration["name"].length <= 60 &&
               configuration["kind"] == "users" && valid_object &&
               %w[daily hourly weekly manual].include?(configuration["schedule"]) && valid_scope &&
               configuration["mappings"].is_a?(Array) && configuration["mappings"].size <= 50
        raise Discourse::InvalidParameters.new(:configuration)
      end

      ConfiguredUserSync.validate_mappings!(
        configuration,
        Api.new.writable_fields(configuration["object"]),
      )
      configuration["group_id"] = Group.find_by!(name: configuration["group"]).id

      %w[onJoin onChange backfill].each do |key|
        configuration[key] = ActiveModel::Type::Boolean.new.cast(configuration[key])
      end

      DistributedMutex.synchronize("salesforce_guided_sync_configurations") do
        records = all
        previous = id ? records.find { |record| record["id"] == id } : nil
        raise Discourse::NotFound if id && !previous
        if previous && previous["object"] != configuration["object"]
          raise Discourse::InvalidParameters.new(:object)
        end
        record_id = previous&.dig("id") || SecureRandom.uuid
        record =
          configuration.except("workflows").merge(
            "id" => record_id,
            "active" => true,
            "instance_url" => SiteSetting.salesforce_instance_url,
          )
        PluginStore.set(
          PLUGIN_NAME,
          STORE_KEY,
          records.reject { |entry| entry["id"] == record_id } + [record],
        )
        if !previous || !previous["active"] || previous["schedule"] != record["schedule"]
          PluginStore.set(PLUGIN_NAME, "configuration_scheduled_at:#{record_id}", Time.now.to_i)
        end
        if record["backfill"] &&
             (
               !previous || !previous["active"] || !previous["backfill"] ||
                 previous["group_id"] != record["group_id"]
             )
          Jobs.enqueue(
            :sync_salesforce_configuration,
            configuration_id: record_id,
            reason: "backfill",
          )
        end
        record
      end
    end
  end
end
