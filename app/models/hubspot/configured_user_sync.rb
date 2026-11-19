# frozen_string_literal: true

module Hubspot
  class ConfiguredUserSync
    def self.validate_mappings!(configuration, fields, validate_static_values: true)
      DiscourseCrm::FieldMapping.validate!(
        configuration.mappings,
        fields,
        email_field: "email",
        required_fields: [],
      )
      return unless validate_static_values
      static_values =
        configuration
          .mappings
          .select { |mapping| mapping["source"] == "static" }
          .to_h { |mapping| [mapping["destination"], mapping["value"]] }
      validate_values!(static_values, fields)
    end

    def self.validate_values!(values, fields)
      fields.each do |field|
        next unless field.key?("options") && values.key?(field["name"])
        value = values[field["name"]]
        next if value.nil? || value == ""
        options =
          field["type"] == "multipicklist" ? value.to_s.delete_prefix(";").split(";", -1) : [value]
        next if (options - field["options"]).empty?
        raise InvalidPropertyValue.new(field["name"])
      end
    end

    def self.sync(configuration_id, user_id, reason: nil)
      return unless DiscourseCrm::SyncConfiguration.enabled?
      DistributedMutex.synchronize("hubspot_person_create_#{user_id}", validity: 5.minutes) do
        configuration =
          DiscourseCrm::SyncConfiguration.active.outbound.find_by(
            id: configuration_id,
            provider: "hubspot",
          )
        return unless configuration&.reason_enabled?(reason) && Hubspot::SyncProvider.credentials?
        user =
          DiscourseCrm::UserEligibility.eligible_group_members(
            configuration.configuration_groups.select(:group_id),
          ).find_by(id: user_id)
        return unless user && DiscourseCrm::UserEligibility.email_verified?(user)
        new(configuration, user).sync(skip_unchanged: reason == "change")
      end
    end

    def initialize(configuration, user, api: Api.new, sources: nil)
      @configuration = configuration
      @user = user
      @api = api
      @sources = sources || DiscourseCrm::UserSyncSources.new(configuration.mappings, [user])
    end

    def sync(skip_unchanged: false)
      if @configuration.connection_changed? || @configuration.account != @api.account
        raise Discourse::InvalidParameters.new(:hubspot_portal_id)
      end
      return if skip_unchanged && unchanged?

      fields = @api.cached_writable_fields(@configuration.object)
      self.class.validate_mappings!(@configuration, fields, validate_static_values: false)
      record = existing_record
      values = mapped_values(record, fields)
      if record
        id = record.fetch("id")
        save_link(id)
        if values.present?
          @api.patch("objects/contacts/#{ERB::Util.url_encode(id)}", properties: values)
        end
      else
        id =
          @api.post("objects/contacts", properties: values.merge("email" => @user.email)).fetch(
            "id",
          )
      end
      complete(id)
    end

    def fingerprint
      @fingerprint ||=
        @sources.fingerprint(
          @user,
          context: {
            account: @configuration.account,
            mappings: @configuration.mappings,
          },
        )
    end

    def unchanged?
      DiscourseCrm::SyncState.find_by(
        configuration_id: @configuration.id,
        user_id: @user.id,
      )&.synced?(fingerprint)
    end

    def complete(id)
      save_link(id)
      DiscourseCrm::SyncState.store(@configuration.id, @user.id, fingerprint: fingerprint)
      DiscourseCrm::SyncConfiguration.record_result(@configuration.id, @user.id)
    end

    def mapped_values(record, fields, refresh: true)
      refreshed = false
      begin
        values =
          DiscourseCrm::FieldMapping
            .new(@configuration.mappings, fields) { |source| @sources.value(source, @user) }
            .values(record && record.fetch("properties"))
        self.class.validate_values!(values, fields)
        values
      rescue InvalidPropertyValue
        raise if refreshed || !refresh
        refreshed = true
        fields = @api.cached_writable_fields(@configuration.object, refresh: true)
        self.class.validate_mappings!(@configuration, fields, validate_static_values: false)
        retry
      end
    end

    def save_link(id)
      DiscourseCrm::RecordLink.transaction do
        previous_id = @configuration.record_link_for(@user.id)&.external_id
        DiscourseCrm::RecordLink.link!(
          provider: "hubspot",
          account: @configuration.account,
          object: "contact",
          user_id: @user.id,
          external_id: id,
        )
        invalidate_fingerprints if previous_id && previous_id != id
        related_sync_states.where(error: MissingContact.name).update_all(
          fingerprint: nil,
          error: nil,
          error_at: nil,
        )
      end
    end

    private

    def existing_record
      properties = @configuration.mappings.map { |mapping| mapping["destination"] }.join(",")
      if link = @configuration.record_link_for(@user.id)
        record = linked_record(link, properties)
        return record if record
      end
      record_by_email(properties)
    end

    def record_by_email(properties)
      @api.get(
        "objects/contacts/#{ERB::Util.url_encode(@user.email)}",
        { idProperty: "email", properties: properties },
        allow_not_found: true,
      )
    end

    def linked_record(link, properties)
      path = "objects/contacts/#{ERB::Util.url_encode(link.external_id)}"
      @api.get(path, properties: properties)
    rescue Hubspot::InvalidApiResponse => error
      raise unless error.status == 404
      archived = @api.get(path, archived: true, allow_not_found: true)
      unless archived
        replacement = record_by_email(properties)
        return replacement if replacement
        raise MissingContact.new
      end
      unless archived.is_a?(Hash) && archived["archived"] == true &&
               archived["id"] == link.external_id
        raise error
      end
      DiscourseCrm::RecordLink.transaction do
        removed =
          DiscourseCrm::RecordLink.unlink!(
            provider: "hubspot",
            account: @configuration.account,
            object: "contact",
            user_id: @user.id,
            external_id: link.external_id,
          )
        raise error unless removed
        invalidate_fingerprints
      end
      nil
    end

    def invalidate_fingerprints
      related_sync_states.update_all(fingerprint: nil)
    end

    def related_sync_states
      configurations =
        DiscourseCrm::SyncConfiguration.outbound.where(
          provider: "hubspot",
          account: @configuration.account,
          object: "contact",
        )
      DiscourseCrm::SyncState.where(configuration_id: configurations.select(:id), user_id: @user.id)
    end
  end
end
