# frozen_string_literal: true

module Hubspot
  class ConfiguredUserBatchSync
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
      by_id =
        @api
          .batch_read_contacts(links.values.map(&:external_id).uniq, properties: properties)
          .index_by { |record| record.fetch("id") }
      unlinked = @users.reject { |user| links.key?(user.id) }
      by_email = {}
      @api
        .batch_read_contacts_by_email(unlinked.map(&:email), properties: properties)
        .each do |record|
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
          SyncFailure.record(@configuration.id, user.id, error)
          processed(user)
          next
        end
        if record
          @syncs.fetch(user.id).save_link(record.fetch("id"))
          if values.empty?
            complete(user, record.fetch("id"))
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
    end

    private

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
        entries.each { |user, _| retry_user(user, error, retryable: true) }
        return
      end

      errors =
        Array(response["errors"]).filter_map do |item|
          next unless item.is_a?(Hash)
          status = item["category"] == "VALIDATION_ERROR" ? 400 : nil
          error = InvalidApiResponse.from_response(item.to_json, status: status)
          DiscourseCrm::ConnectionError.log(
            error,
            operation: "batch_#{operation}",
            provider: "hubspot",
          )
          [Array(item.dig("context", "objectWriteTraceId")), error]
        end

      entries.each do |user, input|
        matches =
          response["results"].select do |record|
            if operation == "update"
              record["id"] == input[:id]
            else
              record["objectWriteTraceId"] == user.id.to_s ||
                record.dig("properties", "email").to_s.casecmp?(user.email)
            end
          end
        if matches.size == 1 && matches.first["id"].present?
          complete(user, matches.first.fetch("id"))
        else
          error = errors.find { |trace_ids, _| trace_ids.include?(user.id.to_s) }&.last
          retry_user(user, error)
        end
      end
    end

    def complete(user, id)
      @syncs.fetch(user.id).complete(id)
      processed(user)
    end

    def processed(user)
      @on_processed.call(user.id)
    end

    def retry_user(user, error = nil, retryable: nil)
      error ||= InvalidApiResponse.new("Contact requires individual reconciliation")
      SyncFailure.record(@configuration.id, user.id, error)
      if retryable || SyncFailure.retryable?(error)
        Jobs.enqueue(
          Jobs::Hubspot::PushUser,
          configuration_id: @configuration.id,
          user_id: user.id,
          reason: @reason,
        )
      end
      processed(user)
    end
  end
end
