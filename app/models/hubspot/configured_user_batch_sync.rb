# frozen_string_literal: true

module Hubspot
  class ConfiguredUserBatchSync
    class BatchReadFailure < StandardError
      attr_reader :provider_error, :matched_user_id

      def initialize(provider_error, matched_user_id)
        super("HubSpot rejected the batch read")
        @provider_error = provider_error
        @matched_user_id = matched_user_id
      end
    end

    def self.sync(configuration, ids, reason:, &on_processed)
      return unless SyncProvider.credentials?
      with_user_locks(ids.sort) do
        users =
          DiscourseCrm::UserEligibility
            .eligible_group_members(configuration.configuration_groups.select(:group_id))
            .where(id: ids)
            .order(:id)
            .includes(:primary_email, :email_tokens, :single_sign_on_record)
            .select { |user| DiscourseCrm::UserEligibility.email_verified?(user) }
        (ids - users.map(&:id)).each { |id| on_processed.call(id) }
        next if users.empty?
        new(configuration, users, reason).sync(&on_processed)
      end
    end

    def self.with_user_locks(ids, index = 0, &block)
      return yield if index == ids.size
      DistributedMutex.synchronize("hubspot_person_create_#{ids[index]}", validity: 5.minutes) do
        with_user_locks(ids, index + 1, &block)
      end
    end
    private_class_method :with_user_locks

    def initialize(configuration, users, reason)
      @configuration = configuration
      @users = users
      @reason = reason
      @api = Api.new
      sources = DiscourseCrm::UserSyncSources.new(configuration.mappings, users)
      @syncs =
        users.to_h do |user|
          [user.id, ConfiguredUserSync.new(configuration, user, api: @api, sources: sources)]
        end
    end

    def sync(&on_processed)
      @on_processed = on_processed
      if @configuration.connection_changed? || @configuration.account != @api.account
        raise Discourse::InvalidParameters.new(:hubspot_portal_id)
      end
      @users =
        @users.reject do |user|
          next false unless @reason == "change" && @syncs.fetch(user.id).unchanged?
          processed(user)
          true
        end
      return if @users.empty?

      @fields = @api.cached_writable_fields(@configuration.object)
      ConfiguredUserSync.validate_mappings!(@configuration, @fields, validate_static_values: false)
      links = @configuration.record_links.where(user_id: @users.map(&:id)).index_by(&:user_id)
      properties =
        (
          @configuration.mappings.map { |mapping| mapping["destination"] } +
            %w[email hs_additional_emails]
        ).uniq
      unlinked = @users.reject { |user| links.key?(user.id) }
      linked_errors = {}
      email_errors = {}
      begin
        by_id =
          @api
            .batch_read_contacts(
              links.values.map(&:external_id).uniq,
              properties: properties,
            ) { |error| linked_errors[error.rejected_email&.downcase] = error }
            .index_by { |record| record.fetch("id") }
        lookup_users = unlinked
        requested_emails = unlinked.map { |user| user.email.downcase }.to_set
        contacts =
          @api.batch_read_contacts_by_email(
            unlinked.map(&:email),
            properties: properties,
          ) do |error|
            email = error.rejected_email&.downcase
            email_errors[requested_emails.include?(email) ? email : nil] = error
          end
      rescue InvalidApiResponse => error
        rejected_email = error.rejected_email
        raise unless rejected_email || Array(error.diagnostics[:codes]).include?("INVALID_EMAIL")
        matching = Array(lookup_users)
        matching = matching.select { |user| user.email.casecmp?(rejected_email) } if rejected_email
        raise BatchReadFailure.new(error, matching.one? ? matching.first.id : nil)
      end
      by_email = {}
      contacts.each do |record|
        emails = [
          record.dig("properties", "email"),
          *record.dig("properties", "hs_additional_emails").to_s.split(";"),
        ]
        emails.compact.each { |email| (by_email[email.downcase] ||= []) << record }
      end
      creates = []
      updates = []
      used_ids = Set.new
      @users.each do |user|
        link = links[user.id]
        matches =
          link ? [by_id[link.external_id]].compact : by_email.fetch(user.email.downcase, []).uniq
        error =
          partial_read_error(
            link ? linked_errors : email_errors,
            matches,
            email: link ? nil : user.email,
            single_input: link ? links.one? : unlinked.one?,
          )
        if error
          retry_user(user, error)
          next
        end
        if (link && matches.empty?) || matches.size > 1
          retry_user(user)
          next
        end
        record = matches.first
        if record && !used_ids.add?(record.fetch("id"))
          retry_user(user)
          next
        end
        begin
          values = mapped_values(user, record)
        rescue InvalidPropertyValue, Discourse::InvalidParameters => error
          SyncActivity.record_failure(@configuration, user.id, error)
          processed(user)
          next
        end
        if record
          @syncs.fetch(user.id).save_link(record.fetch("id"))
          if values.empty?
            complete(user, record.fetch("id"), created: false, changed: false)
          else
            updates << [user, { id: record.fetch("id"), properties: values }]
          end
        else
          creates << [
            user,
            { objectWriteTraceId: user.id.to_s, properties: values.merge("email" => user.email) },
          ]
        end
      end
      write_batch("update", updates)
      write_batch("create", creates)
      DiscourseCrm::SyncConfiguration.record_batch_success(@configuration.id)
    end

    private

    def partial_read_error(errors, matches, email:, single_input:)
      return if errors.empty?
      attributed = errors[email.downcase] if email
      attributed ||= errors[nil] if single_input
      return attributed if matches.empty? && attributed
      return if !attributed && (matches.any? || (email && !errors.key?(nil)))
      InvalidApiResponse.new("Invalid contact batch read response")
    end

    def mapped_values(user, record)
      @syncs.fetch(user.id).mapped_values(record, @fields, refresh: false)
    rescue InvalidPropertyValue
      raise if @refreshed_fields
      @refreshed_fields = true
      @fields = @api.cached_writable_fields(@configuration.object, refresh: true)
      ConfiguredUserSync.validate_mappings!(@configuration, @fields, validate_static_values: false)
      retry
    end

    def write_batch(operation, entries)
      return if entries.empty?
      begin
        response = @api.post("objects/contacts/batch/#{operation}", inputs: entries.map(&:last))
        unless response.is_a?(Hash) && response["results"].is_a?(Array) &&
                 [nil, "COMPLETE", "COMPLETED"].include?(response["status"])
          raise InvalidApiResponse.new("Invalid contact batch write response")
        end
      rescue RateLimited, InvalidCredentials, DailyQuotaExceeded
        raise
      rescue InvalidApiResponse,
             Faraday::TimeoutError,
             Faraday::ConnectionFailed,
             JSON::ParserError => error
        if error.is_a?(InvalidApiResponse) && !error.retryable? &&
             ![400, 409].include?(error.status)
          raise
        end
        ids = entries.map { |user, _| user.id }
        if error.is_a?(InvalidApiResponse) && [400, 409].include?(error.status) &&
             (entries.many? || error.rejected_email)
          errors = batch_errors_by_user(entries, error)
          @configuration.record_batch_failure(ids, error: error) { |id| errors.fetch(id) }
        else
          @configuration.record_batch_failure(ids, error: error)
        end
        entries.each do |user, _|
          enqueue_user_retry(user)
          processed(user)
        end
        return
      end

      confirmed_errors = {}
      batch_errors = {}
      Array(response["errors"]).each do |item|
        next unless item.is_a?(Hash)
        status = item["category"] == "VALIDATION_ERROR" ? 400 : nil
        error = InvalidApiResponse.from_response(item.to_json, status: status)
        DiscourseCrm::ConnectionError.log(
          error,
          operation: "batch_#{operation}",
          provider: "hubspot",
        )
        context = item["context"]
        trace_ids = context.is_a?(Hash) ? Array(context["objectWriteTraceId"]) : []
        affected =
          if trace_ids.empty?
            entries
          else
            entries.select { |user, _| trace_ids.include?(user.id.to_s) }
          end
        if !error.rejected_email && (trace_ids.any? || affected.one?)
          affected.each { |user, _| confirmed_errors[user.id] ||= error }
        else
          batch_errors_by_user(affected, error).each do |id, scoped|
            if scoped.equal?(error)
              confirmed_errors[id] ||= error
            else
              batch_errors[id] ||= scoped
            end
          end
        end
      end

      results = response.fetch("results").grep(Hash)
      id_counts = results.pluck("id").tally
      entries.each do |user, input|
        matches =
          results.select do |record|
            if operation == "update"
              record["id"] == input[:id]
            else
              created_contact_matches?(record, user)
            end
          end
        id = matches.one? ? matches.first["id"] : nil
        if confirmed_errors.key?(user.id) && matches.any?
          retry_user(user)
        elsif id.present? && id_counts[id] == 1
          complete(user, id, created: operation == "create")
        else
          error = confirmed_errors[user.id]
          retry_user(user, error || batch_errors[user.id], retryable: error.nil?)
        end
      end
    end

    def created_contact_matches?(record, user)
      trace = record["objectWriteTraceId"]
      properties = record["properties"]
      email = properties["email"] if properties.is_a?(Hash)
      return false if trace.present? && trace != user.id.to_s
      return false if email.present? && !user.email.casecmp?(email.to_s)
      trace.present? || email.present?
    end

    def batch_errors_by_user(entries, error)
      rejected_email = error.rejected_email
      matching =
        entries.select do |_, input|
          rejected_email && input[:properties]["email"]&.casecmp?(rejected_email)
        end
      generic = InvalidApiResponse.new("Contact batch rejected", status: error.status)
      entries.to_h do |user, _|
        [user.id, matching.one? && matching.first.first.id == user.id ? error : generic]
      end
    end

    def complete(user, id, created:, changed: true)
      result = @syncs.fetch(user.id).complete(id, created: created, changed: changed)
      processed(user, result)
    end

    def processed(user, result = nil)
      @on_processed.call(user.id, result)
    end

    def retry_user(user, error = nil, retryable: nil)
      error ||= InvalidApiResponse.new("Contact requires individual reconciliation")
      SyncActivity.record_failure(@configuration, user.id, error)
      enqueue_user_retry(user) if retryable || SyncFailure.retryable?(error)
      processed(user)
    end

    def enqueue_user_retry(user)
      Jobs.enqueue(
        Jobs::Hubspot::PushUser,
        configuration_id: @configuration.id,
        user_id: user.id,
        reason: @reason,
      )
    end
  end
end
