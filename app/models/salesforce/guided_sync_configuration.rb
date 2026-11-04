# frozen_string_literal: true

module Salesforce
  class GuidedSyncConfiguration
    STORE_KEY = "guided_sync_configurations"

    def self.all
      records = stored_records
      ids = records.flat_map { |record| group_ids(record) }.uniq
      names = groups_by_id(ids).to_h { |group| [group.id, group.name] }
      records.map do |record|
        display =
          record.merge("groups" => group_ids(record).filter_map { |id| names[id.to_i] }.sort)
        display["connection_changed"] = true if record["instance_url"] !=
          SiteSetting.salesforce_instance_url
        display
      end
    end

    def self.group_ids(record)
      Array(record["group_ids"])
    end

    def self.resolve_group_ids!(ids)
      unless ids.is_a?(Array) && ids.present? && ids.size <= 100 &&
               ids.all? { |id| id.to_s.match?(/\A\d+\z/) }
        raise Discourse::InvalidParameters.new(:group_ids)
      end
      ids = ids.map(&:to_i).uniq
      groups = groups_by_id(ids)
      raise Discourse::InvalidParameters.new(:group_ids) if groups.size != ids.size
      groups
    end

    def self.groups_by_id(ids)
      Group.where.not(id: Group::AUTO_GROUPS[:everyone]).where(id: ids).to_a
    end

    def self.available_groups(query: nil)
      groups = Group.where.not(id: Group::AUTO_GROUPS[:everyone])
      if query.present?
        pattern = "%#{Group.sanitize_sql_like(query.to_s.first(100))}%"
        groups = groups.where("name ILIKE ?", pattern)
      end
      counts =
        GroupUser
          .where(group_id: groups.select(:id), user_id: Person.eligible_users.select(:id))
          .group(:group_id)
          .count
      groups
        .order(:name)
        .pluck(:id, :name)
        .map { |id, name| { id: id, name: name, user_count: counts.fetch(id, 0) } }
    end

    def self.enabled?
      SiteSetting.salesforce_enabled && SiteSetting.enable_guided_sync_configuration
    end

    def self.active
      return [] unless enabled?
      stored_records.select do |record|
        record["active"] && record["kind"] == "users" && record["provider"] == "salesforce" &&
          record["instance_url"] == SiteSetting.salesforce_instance_url
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

    def self.record_result(id, user_id = nil, error: nil)
      DistributedMutex.synchronize("salesforce_configuration_status_#{id}") do
        key = "configuration_status:#{id}"
        status = PluginStore.get(PLUGIN_NAME, key) || { "user_errors" => {} }
        if error
          error_info = { "at" => Time.now.utc.iso8601, "error" => error.class.name }
          if user_id
            status["user_errors"][user_id.to_s] = error_info
          else
            status["batch_error"] = error_info
          end
        else
          status["last_synced_at"] = Time.now.utc.iso8601
          status["user_errors"].delete(user_id.to_s) if user_id
        end
        PluginStore.set(PLUGIN_NAME, key, status)
      end
    end

    def self.record_batch_success(id)
      DistributedMutex.synchronize("salesforce_configuration_status_#{id}") do
        key = "configuration_status:#{id}"
        status = PluginStore.get(PLUGIN_NAME, key) || { "user_errors" => {} }
        status.delete("batch_error")
        PluginStore.set(PLUGIN_NAME, key, status)
      end
    end

    def self.status_for(record)
      id = record.fetch("id")
      DistributedMutex.synchronize("salesforce_configuration_status_#{id}") do
        key = "configuration_status:#{id}"
        stored_status = PluginStore.get(PLUGIN_NAME, key)
        next unless stored_status
        status = stored_status
        eligible_ids =
          Person
            .eligible_group_members(group_ids(record))
            .where(id: status["user_errors"].keys.map(&:to_i))
            .pluck(:id)
            .map(&:to_s)
        status["user_errors"].select! { |user_id, _| eligible_ids.include?(user_id) }
        errors = status["user_errors"].values
        displayed_error = status["batch_error"] || errors.first
        PluginStore.set(PLUGIN_NAME, key, status)
        display_status = status.except("user_errors", "batch_error")
        if displayed_error
          display_status["error"] = displayed_error["error"]
          display_status["last_error_at"] = displayed_error["at"]
        end
        display_status
      end
    end

    def self.destroy!(id:, guardian:)
      raise Discourse::InvalidAccess unless guardian.is_admin?

      DistributedMutex.synchronize("salesforce_guided_sync_configurations") do
        records = stored_records
        raise Discourse::NotFound unless records.any? { |record| record["id"] == id }
        PluginStore.set(PLUGIN_NAME, STORE_KEY, records.reject { |record| record["id"] == id })
        PluginStore.remove(PLUGIN_NAME, "configuration_status:#{id}")
        PluginStore.remove(PLUGIN_NAME, "configuration_scheduled_at:#{id}")
        PluginStoreRow
          .where(plugin_name: PLUGIN_NAME)
          .where("key LIKE ?", "configuration_user_fingerprint:#{id}:%")
          .delete_all
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
      groups = resolve_group_ids!(configuration["group_ids"])
      valid_object = %w[Lead Contact].include?(configuration["object"])
      unless configuration["name"].present? && configuration["name"].length <= 60 &&
               configuration["kind"] == "users" && valid_object &&
               %w[daily hourly weekly manual].include?(configuration["schedule"]) &&
               configuration["mappings"].is_a?(Array) && configuration["mappings"].size <= 50
        raise Discourse::InvalidParameters.new(:configuration)
      end

      ConfiguredUserSync.validate_mappings!(
        configuration,
        Api.cached_writable_fields(configuration["object"], refresh: true),
      )
      configuration["group_ids"] = groups.sort_by(&:name).map(&:id)

      configuration["backfill"] = ActiveModel::Type::Boolean.new.cast(configuration["backfill"])

      DistributedMutex.synchronize("salesforce_guided_sync_configurations") do
        records = stored_records
        previous = id ? records.find { |record| record["id"] == id } : nil
        raise Discourse::NotFound if id && !previous
        if previous && previous["object"] != configuration["object"]
          raise Discourse::InvalidParameters.new(:object)
        end
        record_id = previous&.dig("id") || SecureRandom.uuid
        record =
          configuration.merge(
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

    def self.stored_records
      PluginStore.get(PLUGIN_NAME, STORE_KEY) || []
    end
    private_class_method :stored_records
  end
end
