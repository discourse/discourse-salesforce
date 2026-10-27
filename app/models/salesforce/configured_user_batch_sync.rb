# frozen_string_literal: true

module Salesforce
  class ConfiguredUserBatchSync
    BATCH_SIZE = 100

    def self.sync(configuration_id, user_ids, reason:)
      return unless GuidedSyncConfiguration.enabled?
      ids = Array(user_ids).map(&:to_i).uniq.sort
      raise Discourse::InvalidParameters.new(:user_ids) if ids.size > BATCH_SIZE
      with_user_locks(ids) do
        configuration =
          GuidedSyncConfiguration.active.find { |record| record["id"] == configuration_id }
        next unless configuration && GuidedSyncConfiguration.reason_enabled?(configuration, reason)
        users =
          Person
            .eligible_group_members(GuidedSyncConfiguration.group_ids(configuration))
            .where(id: ids)
            .order(:id)
            .to_a
        next if users.empty?
        new(configuration, users, reason).sync
      end
    end

    def self.with_user_locks(ids, index = 0, &block)
      return yield if index == ids.size
      # Share the creation lock with single-user and legacy jobs; acquire in ID order.
      DistributedMutex.synchronize("salesforce_person_create_#{ids[index]}", validity: 600) do
        with_user_locks(ids, index + 1, &block)
      end
    end
    private_class_method :with_user_locks

    def initialize(configuration, users, reason)
      @configuration = configuration
      @users = users
      @reason = reason
      @api = Api.new
      @api.faraday.options.timeout = 30
      @api.faraday.options.open_timeout = 10
      @object = configuration.fetch("object")
    end

    def sync
      if @configuration["instance_url"] != SiteSetting.salesforce_instance_url
        raise Discourse::InvalidParameters.new(:salesforce_instance_url)
      end
      fields = @api.writable_fields(@object)
      ConfiguredUserSync.validate_mappings!(@configuration, fields)
      links =
        @users.to_h do |user|
          [user.id, PluginStore.get(PLUGIN_NAME, "configured_user_link:#{@object}:#{user.id}")]
        end
      records = existing_records(links)
      by_id = records.index_by { |record| record["Id"] }
      by_email = records.group_by { |record| record["Email"].to_s.downcase }
      creates = []
      updates = []
      used_ids = Set.new
      source_data = UserSyncSources.new(@configuration["mappings"], @users)
      @users.each do |user|
        link = links[user.id]
        if link && (link["instance"] != SiteSetting.salesforce_instance_url || !by_id[link["id"]])
          retry_user(user)
          next
        end
        matches = link ? [by_id.fetch(link["id"])] : by_email.fetch(user.email.downcase, [])
        if matches.size > 1
          retry_user(user, AmbiguousEmailMatch.new(@object))
          next
        end
        record = matches.first
        if record && !used_ids.add?(record["Id"])
          retry_user(user)
          next
        end
        sync = ConfiguredUserSync.new(@configuration, user, api: @api, source_data: source_data)
        values = sync.mapped_values(fields, record)
        if record && values.empty?
          sync.complete(record.fetch("Id"))
        elsif record
          updates << [user, sync, values.merge("Id" => record.fetch("Id"))]
        else
          creates << [user, sync, values.merge("Email" => user.email)]
        end
      end
      write_collection(:post, creates)
      write_collection(:patch, updates)
    end

    private

    def existing_records(links)
      fields = [
        "Id",
        "Email",
        *@configuration["mappings"].map { |mapping| mapping["destination"] },
      ].uniq
      unless fields.all? { |field| Person::FIELD_NAME_PATTERN.match?(field) }
        raise Discourse::InvalidParameters.new(:mappings)
      end
      @users
        .each_slice(25)
        .flat_map do |users|
          ids = users.filter_map { |user| links[user.id]&.fetch("id") }.uniq
          conditions = ["Email IN (#{quoted(users.map(&:email))})"]
          conditions << "Id IN (#{quoted(ids)})" if ids.present?
          result =
            @api.query(
              "SELECT #{fields.join(",")} FROM #{@object} WHERE #{conditions.join(" OR ")}",
            )
          records = result.fetch("records")
          while result["nextRecordsUrl"]
            path = result.fetch("nextRecordsUrl")
            unless path.start_with?("#{@api.prefix}/query/")
              raise InvalidApiResponse.new("Invalid query continuation")
            end
            result = @api.get(path.delete_prefix("#{@api.prefix}/"))
            records.concat(result.fetch("records"))
          end
          records
        end
        .uniq { |record| record["Id"] }
    end

    def quoted(values)
      values.map { |value| "'#{Person.escape_soql_string(value)}'" }.join(",")
    end

    def write_collection(method, entries)
      return if entries.empty?
      records = entries.map { |_, _, values| values.merge("attributes" => { "type" => @object }) }
      begin
        results =
          @api.public_send(method, "composite/sobjects", { allOrNone: false, records: records })
        unless results.is_a?(Array) && results.size == entries.size &&
                 results.all? { |result| result.is_a?(Hash) }
          raise InvalidApiResponse.new("Invalid collection response")
        end
      rescue InvalidApiResponse, Faraday::Error => error
        entries.each { |user, _, _| retry_user(user, error) }
        return
      end
      entries
        .zip(results)
        .each do |(user, sync, _), result|
          if result["success"] == true && result["id"].present?
            sync.complete(result.fetch("id"))
          else
            retry_user(user, InvalidApiResponse.new(result.fetch("errors", []).to_json))
          end
        end
    end

    def retry_user(user, error = nil)
      GuidedSyncConfiguration.record_result(@configuration["id"], user.id, error: error) if error
      Jobs.enqueue(
        :sync_salesforce_user,
        configuration_id: @configuration["id"],
        user_id: user.id,
        reason: @reason,
      )
    end
  end
end
