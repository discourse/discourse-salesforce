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
      ["email", Api::LAST_MODIFIED_PROPERTY, Api::COMPANY_PROPERTY, *contact_properties].uniq
    end

    def pulls_companies?
      company_properties.any?
    end

    def import_page(contacts)
      by_email = {}
      contacts.each do |contact|
        email = contact.dig("properties", "email").to_s.downcase
        by_email[email] = contact if email.present?
      end
      matches =
        DiscourseCrm::UserEligibility
          .eligible_users
          .with_email(by_email.keys)
          .pluck("users.id", "user_emails.email")
      links = []
      records = {}
      matches.each do |user_id, email|
        contact = by_email.fetch(email.downcase)
        links << scope.merge(direction: "inbound", user_id: user_id, external_id: contact["id"])
        records[contact["id"]] ||= scope.merge(
          external_id: contact["id"],
          company_external_id: contact.dig("properties", Api::COMPANY_PROPERTY).presence,
          data: contact.fetch("properties").slice(*contact_properties),
        )
      end
      contact_ids = by_email.values.map { |contact| contact["id"] }
      previous_company_ids = company_ids_of(contact_ids)
      DiscourseCrm::RecordLink.link_many!(links)
      DiscourseCrm::Record.store_many!(records.values)
      keep = links.map { |link| [link[:user_id], link[:external_id]] }
      stale_links =
        @configuration
          .record_links
          .where(external_id: contact_ids)
          .pluck(:id, :user_id, :external_id)
          .filter_map { |id, user_id, external_id| id if keep.exclude?([user_id, external_id]) }
      DiscourseCrm::RecordLink.where(id: stale_links).delete_all if stale_links.any?
      remove_orphans(contact_ids, previous_company_ids)
      if pulls_companies?
        refresh_companies(records.values.filter_map { |record| record[:company_external_id] }.uniq)
      else
        company_records.delete_all
      end
      links
    end

    def import_user(user)
      contacts = @api.batch_read_contacts_by_email(user.emails, properties: requested_properties)
      kept =
        import_page(contacts).filter_map { |link| link[:external_id] if link[:user_id] == user.id }
      stale = @configuration.record_links.where(user_id: user.id).where.not(external_id: kept)
      stale_ids = stale.pluck(:external_id)
      return if stale_ids.empty?
      previous_company_ids = company_ids_of(stale_ids)
      stale.delete_all
      remove_orphans(stale_ids, previous_company_ids)
    end

    def refresh_companies(ids)
      return if ids.empty?
      results, missing = @api.batch_read_companies(ids, properties: company_properties)
      rows =
        results.map do |company|
          scope.merge(
            object: "company",
            external_id: company["id"],
            company_external_id: nil,
            data: company.fetch("properties").slice(*company_properties),
          )
        end
      DiscourseCrm::Record.store_many!(rows)
      company_records.where(external_id: missing).delete_all if missing.any?
    end

    def referenced_company_ids(after:, limit: Api::PAGE_SIZE)
      @configuration
        .records
        .where.not(company_external_id: nil)
        .where("company_external_id > ?", after)
        .distinct
        .order(:company_external_id)
        .limit(limit)
        .pluck(:company_external_id)
    end

    private

    def scope
      @configuration.slice(:provider, :account, :object).symbolize_keys
    end

    def contact_properties
      sources("contact")
    end

    def company_properties
      sources("company")
    end

    def sources(object)
      @configuration.mappings.filter_map do |mapping|
        mapping["source"] if mapping["object"] == object
      end
    end

    def company_records
      DiscourseCrm::Record.within(**scope.merge(object: "company"))
    end

    def company_ids_of(contact_ids)
      @configuration
        .records
        .where(external_id: contact_ids)
        .where.not(company_external_id: nil)
        .distinct
        .pluck(:company_external_id)
    end

    def remove_orphans(contact_ids, company_ids)
      if contact_ids.any?
        @configuration
          .records
          .where(external_id: contact_ids)
          .where
          .missing(:record_links)
          .delete_all
      end
      return if company_ids.empty?
      referenced = @configuration.records.where.not(company_external_id: nil)
      company_records
        .where(external_id: company_ids)
        .where.not(external_id: referenced.select(:company_external_id))
        .delete_all
    end
  end
end
