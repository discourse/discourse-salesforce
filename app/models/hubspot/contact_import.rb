# frozen_string_literal: true

module ::Hubspot
  class ContactImport
    def initialize(configuration, api: Api.new)
      if configuration.connection_changed?
        raise Discourse::InvalidParameters.new(:hubspot_portal_id)
      end
      @configuration = configuration
      @api = api
    end

    def requested_properties
      ["email", Api::LAST_MODIFIED_PROPERTY, *selected_properties].uniq
    end

    def import_page(contacts)
      by_email = {}
      contacts.each do |contact|
        email = contact.dig("properties", "email").to_s.downcase
        by_email[email] = contact if email.present?
      end
      matches =
        Salesforce::Person
          .eligible_users
          .with_email(by_email.keys)
          .pluck("users.id", "user_emails.email")
      links = []
      records = {}
      matches.each do |user_id, email|
        contact = by_email.fetch(email.downcase)
        links << scope.merge(user_id: user_id, external_id: contact["id"])
        records[contact["id"]] ||= scope.merge(
          external_id: contact["id"],
          data: contact.fetch("properties").slice(*selected_properties),
        )
      end
      Salesforce::RecordLink.link_many!(links)
      Salesforce::Record.store_many!(records.values)
      contact_ids = by_email.values.map { |contact| contact["id"] }
      keep = links.map { |link| [link[:user_id], link[:external_id]] }
      stale_links =
        @configuration
          .record_links
          .where(external_id: contact_ids)
          .pluck(:id, :user_id, :external_id)
          .filter_map { |id, user_id, external_id| id if keep.exclude?([user_id, external_id]) }
      Salesforce::RecordLink.where(id: stale_links).delete_all if stale_links.any?
      remove_orphan_records(contact_ids)
      links
    end

    def import_user(user)
      contacts = @api.batch_read_contacts_by_email(user.emails, properties: requested_properties)
      kept =
        import_page(contacts).filter_map { |link| link[:external_id] if link[:user_id] == user.id }
      stale = @configuration.record_links.where(user_id: user.id).where.not(external_id: kept)
      stale_ids = stale.pluck(:external_id)
      return if stale_ids.empty?
      stale.delete_all
      remove_orphan_records(stale_ids)
    end

    private

    def scope
      @configuration.slice(:provider, :account, :object).symbolize_keys
    end

    def selected_properties
      @configuration.mappings.map { |mapping| mapping["source"] }
    end

    def remove_orphan_records(contact_ids)
      return if contact_ids.empty?
      @configuration.records.where(external_id: contact_ids).where.missing(:record_links).delete_all
    end
  end
end
