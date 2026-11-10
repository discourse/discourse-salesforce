# frozen_string_literal: true

module Salesforce
  class ConfiguredUserSync
    SYNC_LOCK_VALIDITY = 5.minutes

    def self.validate_mappings!(configuration, fields)
      DiscourseCrm::FieldMapping.validate!(
        configuration.mappings,
        fields,
        email_field: "Email",
        required_fields: Person.for_object(configuration.object)::REQUIRED_MAPPING_FIELDS,
      )
    end

    def self.sync(configuration_id, user_id, reason: nil)
      return unless DiscourseCrm::SyncConfiguration.enabled?
      DistributedMutex.synchronize(
        "salesforce_person_create_#{user_id}",
        validity: SYNC_LOCK_VALIDITY,
      ) do
        configuration = DiscourseCrm::SyncConfiguration.active.find_by(id: configuration_id)
        unless configuration&.provider == "salesforce" && configuration.reason_enabled?(reason)
          return
        end
        user = User.find_by(id: user_id)
        unless user && DiscourseCrm::UserEligibility.auto_create_eligible?(user) &&
                 DiscourseCrm::UserEligibility.email_verified?(user)
          return
        end
        unless GroupUser.exists?(
                 group_id: configuration.configuration_groups.select(:group_id),
                 user_id: user.id,
               )
          return
        end
        new(configuration, user).sync(skip_unchanged: reason == "change")
      end
    end

    def initialize(configuration, user, api: nil, source_data: nil)
      @configuration = configuration
      @user = user
      @person = Person.for_object(configuration.object)
      @api = api || Api.new
      @source_data = source_data
    end

    def sync(skip_unchanged: false)
      if @configuration.connection_changed?
        raise Discourse::InvalidParameters.new(:salesforce_instance_url)
      end
      return if converted_lead_link?
      fingerprint = source_fingerprint
      return if skip_unchanged && sync_state&.fingerprint == fingerprint
      fields = @api.cached_writable_fields(@configuration.object)
      self.class.validate_mappings!(@configuration, fields)
      record = existing_record
      return if record == :converted_lead
      return if record == :conversion_error
      values = mapped_values(fields, record)
      if record
        id = record.fetch("Id")
        save_link(id)
        @api.patch("sobjects/#{@configuration.object}/#{id}", values) if values.present?
      else
        id =
          @api.post(
            "sobjects/#{@configuration.object}",
            values.merge("Email" => @user.email),
          ).fetch("id")
      end
      complete(id)
      DiscourseCrm::SyncState.store(@configuration.id, @user.id, fingerprint: fingerprint)
    end

    def complete(id)
      save_link(id)
      @user.custom_fields[@person::ID_FIELD] = id
      @user.save_custom_fields
      DiscourseCrm::SyncState.where(
        configuration_id: @configuration.id,
        user_id: @user.id,
      ).update_all(fingerprint: nil)
      DiscourseCrm::SyncConfiguration.record_result(@configuration.id, @user.id)
    end

    def reconcile_converted_lead(record)
      contact_id = record["ConvertedContactId"]
      if contact_id.blank?
        return(
          conversion_reconciliation_failed(
            "Converted Lead #{record["Id"]} has no accessible Contact ID",
          )
        )
      end

      if conversion_link_conflict?(record, contact_id)
        return(
          conversion_reconciliation_failed(
            "Converted Lead #{record["Id"]} conflicts with an existing Salesforce Contact or Lead link",
          )
        )
      end

      UserCustomField.transaction do
        DiscourseCrm::RecordLink.mark_converted!(
          **link_scope(object: "Lead"),
          external_id: record["Id"],
          to_object: "Contact",
          to_id: contact_id,
        )
        DiscourseCrm::RecordLink.link!(
          **link_scope(object: "Contact"),
          external_id: contact_id,
          converted_from_id: record["Id"],
        )
        @user.salesforce_lead_id = nil if @user.salesforce_lead_id == record["Id"]
        @user.salesforce_contact_id = contact_id
        @user.save_custom_fields
      end
      DiscourseCrm::SyncConfiguration.record_result(@configuration.id, @user.id)
      true
    end

    def mapped_values(fields, record)
      DiscourseCrm::FieldMapping
        .new(@configuration.mappings, fields) { |source| source_value(source) }
        .values(record)
    end

    def save_link(id)
      DiscourseCrm::RecordLink.link!(**link_scope, external_id: id)
    end

    private

    def link_scope(object: @configuration.object)
      {
        provider: @configuration.provider,
        account: @configuration.account,
        object: object,
        user_id: @user.id,
      }
    end

    def sync_state
      DiscourseCrm::SyncState.find_by(configuration_id: @configuration.id, user_id: @user.id)
    end

    def source_fingerprint
      source_data.fingerprint(
        @user,
        context: {
          instance: SiteSetting.salesforce_instance_url,
          object: @configuration.object,
          mappings: @configuration.mappings,
        },
      )
    end

    def existing_record
      link = @configuration.record_link_for(@user.id)
      record = linked_record(link) if link
      if @person == Lead && record && record["IsConverted"] == true
        return reconcile_converted_lead(record) ? :converted_lead : :conversion_error
      end
      fields = @configuration.mappings.map { |mapping| mapping["destination"] }
      record ||= @person.find_by_email(@user.email, fields: fields, require_unique: true, api: @api)
      if @person == Lead && record.nil?
        converted_lead = Lead.find_converted_by_email(@user.email, api: @api)
        if converted_lead
          return reconcile_converted_lead(converted_lead) ? :converted_lead : :conversion_error
        end
      end
      record
    end

    def converted_lead_link?
      return false unless @person == Lead
      return false unless @configuration.record_link_for(@user.id)&.converted?

      DiscourseCrm::SyncConfiguration.record_result(@configuration.id, @user.id)
      true
    end

    def linked_record(link)
      @api.get("sobjects/#{@configuration.object}/#{link.external_id}")
    rescue Salesforce::InvalidApiResponse => error
      raise unless error.status == 404 && @configuration.object == "Lead"
      id = link.external_id
      raise unless id.match?(/\A[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?\z/)
      query = "SELECT Id, IsDeleted, IsConverted, ConvertedContactId FROM Lead WHERE Id = '#{id}'"
      records = @api.get("queryAll/?q=#{CGI.escape(query)}").fetch("records")
      deleted = records.find { |record| record["Id"] == id }
      if deleted && deleted["IsConverted"] == true
        return(
          {
            "Id" => id,
            "IsConverted" => true,
            "ConvertedContactId" => deleted["ConvertedContactId"],
          }
        )
      end
      raise error unless deleted && deleted["IsDeleted"] == true && deleted["IsConverted"] == false
      nil
    end

    def conversion_link_conflict?(record, contact_id)
      current_lead = DiscourseCrm::RecordLink.find_by(**link_scope(object: "Lead"))
      current_contact = DiscourseCrm::RecordLink.find_by(**link_scope(object: "Contact"))
      legacy_lead_id = @user.salesforce_lead_id
      legacy_contact_id = @user.salesforce_contact_id

      (current_lead && current_lead.external_id != record["Id"]) ||
        (current_contact && current_contact.external_id != contact_id) ||
        (legacy_lead_id.present? && legacy_lead_id != record["Id"]) ||
        (legacy_contact_id.present? && legacy_contact_id != contact_id)
    end

    def conversion_reconciliation_failed(message)
      @conversion_error = LeadConversionReconciliationError.new(message)
      Rails.logger.warn(
        "Skipping converted Salesforce Lead reconciliation for Discourse user #{@user.id}: #{message}",
      )
      DiscourseCrm::SyncConfiguration.record_result(
        @configuration.id,
        @user.id,
        error: @conversion_error,
      )
      false
    end

    def source_data
      @source_data ||= DiscourseCrm::UserSyncSources.new(@configuration.mappings, [@user])
    end

    def source_value(source)
      source_data.value(source, @user)
    end
  end
end
