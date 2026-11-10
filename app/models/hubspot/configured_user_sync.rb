# frozen_string_literal: true

module Hubspot
  class ConfiguredUserSync
    def self.validate_mappings!(configuration, fields)
      DiscourseCrm::FieldMapping.validate!(
        configuration.mappings,
        fields,
        email_field: "email",
        required_fields: [],
      )
    end

    def self.sync(configuration_id, user_id, reason: nil)
      return unless DiscourseCrm::SyncConfiguration.enabled?
      DistributedMutex.synchronize("hubspot_person_create_#{user_id}", validity: 5.minutes) do
        configuration =
          DiscourseCrm::SyncConfiguration.active.find_by(id: configuration_id, provider: "hubspot")
        unless configuration&.reason_enabled?(reason) && configuration.crm_provider.configured?
          return
        end
        user =
          DiscourseCrm::UserEligibility.eligible_group_members(
            configuration.configuration_groups.select(:group_id),
          ).find_by(id: user_id)
        return unless user && DiscourseCrm::UserEligibility.email_verified?(user)
        new(configuration, user).sync(skip_unchanged: reason == "change")
      end
    end

    def initialize(configuration, user)
      @configuration = configuration
      @user = user
      @api = Api.new
      @sources = DiscourseCrm::UserSyncSources.new(configuration.mappings, [user])
    end

    def sync(skip_unchanged: false)
      if @configuration.connection_changed? || @configuration.account != @api.account
        raise Discourse::InvalidParameters.new(:hubspot_portal_id)
      end
      fingerprint =
        @sources.fingerprint(
          @user,
          context: {
            account: @configuration.account,
            mappings: @configuration.mappings,
          },
        )
      state =
        DiscourseCrm::SyncState.find_by(configuration_id: @configuration.id, user_id: @user.id)
      return if skip_unchanged && state&.fingerprint == fingerprint

      fields = @api.cached_writable_fields(@configuration.object)
      self.class.validate_mappings!(@configuration, fields)
      record = existing_record
      values =
        DiscourseCrm::FieldMapping
          .new(@configuration.mappings, fields) { |source| @sources.value(source, @user) }
          .values(record && record.fetch("properties"))
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
        save_link(id)
      end
      DiscourseCrm::SyncState.store(@configuration.id, @user.id, fingerprint: fingerprint)
      DiscourseCrm::SyncConfiguration.record_result(@configuration.id, @user.id)
    end

    private

    def existing_record
      properties = @configuration.mappings.map { |mapping| mapping["destination"] }.join(",")
      if link = @configuration.record_link_for(@user.id)
        record = linked_record(link, properties)
        return record if record
      end
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
      archived = @api.get(path, archived: true)
      unless archived.is_a?(Hash) && archived["archived"] == true &&
               archived["id"] == link.external_id
        raise error
      end
      DiscourseCrm::RecordLink.transaction do
        removed =
          DiscourseCrm::RecordLink.unlink!(
            provider: "hubspot",
            account: @configuration.account,
            object: "Contact",
            user_id: @user.id,
            external_id: link.external_id,
          )
        raise error unless removed
        configurations =
          DiscourseCrm::SyncConfiguration.where(
            provider: "hubspot",
            account: @configuration.account,
            object: "Contact",
          )
        DiscourseCrm::SyncState.where(
          configuration_id: configurations.select(:id),
          user_id: @user.id,
        ).update_all(fingerprint: nil)
      end
      nil
    end

    def save_link(id)
      DiscourseCrm::RecordLink.link!(
        provider: "hubspot",
        account: @configuration.account,
        object: "Contact",
        user_id: @user.id,
        external_id: id,
      )
    end
  end
end
