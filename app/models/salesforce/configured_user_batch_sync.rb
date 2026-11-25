# frozen_string_literal: true

module Salesforce
  class ConfiguredUserBatchSync
    class UnconfirmedCollectionResult < InvalidApiResponse
    end

    BATCH_SIZE = DiscourseCrm::ConfigurationScheduler::BATCH_SIZE

    def self.sync(configuration_id, user_ids, reason:, &on_processed)
      return unless DiscourseCrm::SyncConfiguration.enabled?
      ids = Array(user_ids).map(&:to_i).uniq.sort
      raise Discourse::InvalidParameters.new(:user_ids) if ids.size > BATCH_SIZE
      with_user_locks(ids) do
        configuration =
          DiscourseCrm::SyncConfiguration.active.outbound.find_by(id: configuration_id)
        next unless configuration&.provider == "salesforce" && configuration.reason_enabled?(reason)
        users =
          DiscourseCrm::UserEligibility
            .eligible_group_members(configuration.configuration_groups.select(:group_id))
            .where(id: ids)
            .order(:id)
            .includes(:primary_email, :email_tokens, :single_sign_on_record)
            .select { |user| DiscourseCrm::UserEligibility.email_verified?(user) }
        (ids - users.map(&:id)).each { |id| on_processed&.call(id) }
        next if users.empty?
        new(configuration, users, reason).sync(&on_processed)
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
      @object = configuration.object
    end

    def sync(&on_processed)
      @on_processed = on_processed
      if @configuration.connection_changed?
        raise Discourse::InvalidParameters.new(:salesforce_instance_url)
      end
      links = @configuration.record_links.where(user_id: @users.map(&:id)).index_by(&:user_id)
      users =
        @users.reject do |user|
          converted = @object == "Lead" && links[user.id]&.converted?
          if converted
            result =
              SyncActivity.record_converted_lead(
                @configuration,
                user.id,
                scheduled: @reason == "scheduled",
              )
            processed(user, result)
          end
          converted
        end
      return if users.empty?
      fields = @api.cached_writable_fields(@object)
      ConfiguredUserSync.validate_mappings!(@configuration, fields)
      records = existing_records(links, users)
      by_id = records.index_by { |record| record["Id"] }
      by_email =
        records
          .reject { |record| @object == "Lead" && record["IsConverted"] == true }
          .group_by { |record| record["Email"].to_s.downcase }
      converted_by_email =
        if @object == "Lead"
          records
            .select { |record| record["IsConverted"] == true }
            .group_by { |record| record["Email"].to_s.downcase }
        else
          {}
        end
      creates = []
      updates = []
      used_ids = Set.new
      source_data = DiscourseCrm::UserSyncSources.new(@configuration.mappings, users)
      users.each do |user|
        link = links[user.id]
        if link && !by_id[link.external_id]
          retry_user(user)
          next
        end
        matches = link ? [by_id.fetch(link.external_id)] : by_email.fetch(user.email.downcase, [])
        if matches.size > 1
          retry_user(user, AmbiguousEmailMatch.new(@object))
          next
        end
        record = matches.first
        if @object == "Lead" && record.nil?
          converted_matches = converted_by_email.fetch(user.email.downcase, [])
          if converted_matches.size > 1
            retry_user(user, AmbiguousEmailMatch.new(@object))
            next
          elsif converted_matches.size == 1
            sync = ConfiguredUserSync.new(@configuration, user, api: @api, source_data: source_data)
            sync.reconcile_converted_lead(converted_matches.first)
            processed(user)
            next
          end
        end
        if @object == "Lead" && record && record["IsConverted"] == true
          sync = ConfiguredUserSync.new(@configuration, user, api: @api, source_data: source_data)
          sync.reconcile_converted_lead(record)
          processed(user)
          next
        end
        if record && !used_ids.add?(record["Id"])
          retry_user(user)
          next
        end
        sync = ConfiguredUserSync.new(@configuration, user, api: @api, source_data: source_data)
        begin
          values = sync.mapped_values(fields, record)
        rescue Discourse::InvalidParameters => error
          SyncActivity.record_failure(@configuration, user.id, error)
          processed(user)
          next
        end
        if record && values.empty?
          result = sync.complete(record.fetch("Id"), created: false, changed: false)
          processed(user, result)
        elsif record
          sync.save_link(record.fetch("Id"))
          updates << [user, sync, values.merge("Id" => record.fetch("Id"))]
        else
          creates << [user, sync, values.merge("Email" => user.email)]
        end
      end
      write_collection(:patch, updates)
      creates = exclude_existing_contacts(creates) if @object == "Lead"
      write_collection(:post, creates)
      DiscourseCrm::SyncConfiguration.record_batch_success(@configuration.id)
    end

    private

    def existing_records(links, sync_users)
      fields = [
        "Id",
        "Email",
        *@configuration.mappings.map { |mapping| mapping["destination"] },
      ].uniq
      fields.concat(%w[IsConverted ConvertedContactId]) if @object == "Lead"
      unless fields.all? { |field| Person::FIELD_NAME_PATTERN.match?(field) }
        raise Discourse::InvalidParameters.new(:mappings)
      end
      sync_users
        .each_slice(25)
        .flat_map do |user_batch|
          ids = user_batch.filter_map { |user| links[user.id]&.external_id }.uniq
          conditions = ["Email IN (#{quoted(user_batch.map(&:email))})"]
          conditions << "Id IN (#{quoted(ids)})" if ids.present?
          query_records(
            "SELECT #{fields.join(",")} FROM #{@object} WHERE #{conditions.join(" OR ")}",
          )
        end
        .uniq { |record| record["Id"] }
    end

    def exclude_existing_contacts(creates)
      contact_emails =
        creates
          .each_slice(25)
          .flat_map do |entries|
            emails = entries.map { |user, _, _| user.email }
            query_records(
              "SELECT Email FROM Contact WHERE Email IN (#{quoted(emails)})",
            ).map { |record| record.fetch("Email").downcase }
          end
          .to_set

      creates.reject do |user, _, _|
        next false if contact_emails.exclude?(user.email.downcase)

        SyncActivity.record_existing_contact(@configuration, user.id)
        processed(user)
        true
      end
    end

    def query_records(query)
      result = @api.query(query)
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
          raise UnconfirmedCollectionResult
        end
      rescue Faraday::TimeoutError,
             Faraday::ConnectionFailed,
             JSON::ParserError,
             InvalidApiResponse => error
        raise if error.is_a?(InvalidApiResponse) && error.status && error.status < 500

        # The write may have succeeded remotely; reconcile by ID/email before writing again.
        @configuration.record_batch_failure(entries.map { |user, _, _| user.id }, error: error)
        entries.each { |user, _, _| enqueue_user_retry(user, @reason) }
        return
      end
      result_ids = results.map { |result| comparable_id(result["id"]) }
      counts = result_ids.tally
      entries
        .zip(results, result_ids)
        .each do |(user, sync, values), result, id|
          if result["success"] == false
            retry_user(user, InvalidApiResponse.new(result.fetch("errors", []).to_json))
          elsif result["success"] == true && result.fetch("errors", []) == [] && id &&
                counts[id] == 1 && (method == :post || id == comparable_id(values["Id"]))
            sync.complete(result.fetch("id"), created: method == :post)
            processed(user)
          else
            retry_user(user, UnconfirmedCollectionResult.new)
          end
        end
    end

    def comparable_id(id)
      return unless id.is_a?(String) && id.start_with?(Associations::ID_PREFIXES.fetch(@object))
      id.first(15) if Associations::ID_PATTERN.match?(id)
    end

    def processed(user, result = nil)
      @on_processed&.call(user.id, result)
    end

    def retry_user(user, error = nil)
      reason = @reason
      SyncActivity.record_reconciliation(@configuration, user.id, error: error)
      reason = "retry" if error.nil? && reason == "change"
      enqueue_user_retry(user, reason)
    end

    def enqueue_user_retry(user, reason)
      Jobs.enqueue(
        :sync_salesforce_user,
        configuration_id: @configuration.id,
        user_id: user.id,
        reason: reason,
      )
      processed(user)
    end
  end
end
