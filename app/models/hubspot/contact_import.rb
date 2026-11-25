# frozen_string_literal: true

module ::Hubspot
  class ContactImport
    class CompanyIdentityError < InvalidApiResponse
    end

    CompanyResult = Data.define(:changed, :missing)

    PageResult =
      Data.define(:links, :removed_user_ids, :missing_company_user_ids, :changed_user_ids) do
        def reasons(also_removed: [], summarize_unchanged: false)
          removed = (removed_user_ids | also_removed).to_set
          imported = links.pluck(:user_id).uniq.index_with("imported")
          results =
            removed.index_with("contact_unlinked").merge(imported) { "imported_and_unlinked" }
          if summarize_unchanged
            (imported.keys - changed_user_ids).each do |id|
              results[id] = removed.include?(id) ? "contact_unlinked" : "unchanged"
            end
          end
          missing_company_user_ids.each do |user_id|
            results[user_id] = (
              if removed.include?(user_id)
                "imported_and_unlinked_missing_company"
              else
                "imported_missing_company"
              end
            )
          end
          results
        end
      end

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

    def import_page(contacts, defer_companies: false)
      contacts_by_email =
        contacts.group_by { |contact| contact.dig("properties", "email").to_s.downcase }
      matches =
        DiscourseCrm::UserEligibility
          .eligible_users
          .with_email(contacts_by_email.keys.reject(&:blank?))
          .pluck("users.id", "user_emails.email")
      links = []
      records = {}
      matches.each do |user_id, email|
        contacts_by_email
          .fetch(email.downcase)
          .each do |contact|
            links << scope.merge(direction: "inbound", user_id: user_id, external_id: contact["id"])
            records[contact["id"]] ||= scope.merge(
              external_id: contact["id"],
              company_external_id: contact.dig("properties", Api::COMPANY_PROPERTY).presence,
              data: contact.fetch("properties").slice(*contact_properties),
            )
          end
      end
      company_ids =
        if pulls_companies? && !defer_companies
          records.values.filter_map { |record| record[:company_external_id] }.uniq
        else
          []
        end
      refresh_companies(company_ids, allow_partial_import: true) do |companies|
        page = store_page(contacts.pluck("id"), records, links, companies)
        block_given? ? yield(page) : page
      end
    end

    def import_user(user)
      contacts = @api.batch_read_contacts_by_email(user.emails, properties: requested_properties)
      import_page(contacts) do |page|
        reasons = user_import_reasons(user, page)
        yield reasons if block_given?
        reasons
      end
    end

    def refresh_companies(ids, allow_partial_import: false)
      begin
        rows, missing = fetch_company_rows(ids)
      rescue InvalidApiResponse => error
        raise unless allow_partial_import && recoverable_company_error?(error)
      end

      DiscourseCrm::Record.transaction do
        if error
          DiscourseCrm::SyncAttempt.record(@configuration, nil, error: error)
        else
          changed = DiscourseCrm::Record.store_many!(rows)
          company_records.where(external_id: missing).delete_all if missing.any?
          result = CompanyResult.new(changed, missing)
        end
        block_given? ? yield(result) : result
      end
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

    def store_page(contact_ids, records, links, companies)
      previous_company_ids = company_ids_of(contact_ids)
      new_links = DiscourseCrm::RecordLink.link_many!(links, returning: %w[external_id])
      changed_ids = DiscourseCrm::Record.store_many!(records.values).to_set
      new_links.pluck("external_id").each { |id| changed_ids << id }
      changed_companies = Array(companies&.changed).to_set
      changed_users =
        links.filter_map do |link|
          id = link[:external_id]
          if changed_ids.include?(id) ||
               changed_companies.include?(records.fetch(id)[:company_external_id])
            link[:user_id]
          end
        end
      missing_companies = Array(companies&.missing)
      missing_company_users =
        links
          .filter_map do |link|
            if missing_companies.include?(records.fetch(link[:external_id])[:company_external_id])
              link[:user_id]
            end
          end
          .to_set
      keep = links.to_set { |link| [link[:user_id], link[:external_id]] }
      stale_links =
        @configuration
          .record_links
          .where(external_id: contact_ids)
          .pluck(:id, :user_id, :external_id)
          .reject { |_, user_id, external_id| keep.include?([user_id, external_id]) }
      DiscourseCrm::RecordLink.where(id: stale_links.map(&:first)).delete_all if stale_links.any?
      remove_orphans(contact_ids, previous_company_ids)
      company_records.delete_all unless pulls_companies?
      PageResult.new(
        links,
        stale_links.map { |_, user_id, _| user_id }.uniq,
        missing_company_users,
        changed_users,
      )
    end

    def user_import_reasons(user, page)
      kept = page.links.filter_map { |link| link[:external_id] if link[:user_id] == user.id }
      stale = @configuration.record_links.where(user_id: user.id).where.not(external_id: kept)
      stale_ids = stale.pluck(:external_id)
      if stale_ids.any?
        previous_company_ids = company_ids_of(stale_ids)
        stale.where(external_id: stale_ids).delete_all
        remove_orphans(stale_ids, previous_company_ids)
      end
      reasons = page.reasons(also_removed: stale_ids.any? ? [user.id] : [])
      reasons[user.id] ||= "skipped_no_match"
      reasons
    end

    def fetch_company_rows(ids)
      return [], [] if ids.empty?
      properties = company_properties | ["hs_merged_object_ids"]
      results, missing = @api.batch_read_companies(ids, properties: properties)
      companies = {}
      results.each do |company|
        id = company.fetch("id")
        aliases = company.fetch("properties")["hs_merged_object_ids"].to_s.split(";")
        requested = ids & [id, *aliases]
        if requested.empty?
          raise CompanyIdentityError.new("Unexpected company in batch read response")
        end
        requested.each do |requested_id|
          if companies.key?(requested_id) && companies[requested_id]["id"] != id
            raise CompanyIdentityError.new("Conflicting company IDs in batch read response")
          end
          companies[requested_id] = company
        end
      end
      # A returned company can resolve an ID also listed in a not-found error.
      missing = missing.uniq - companies.keys
      unless (companies.keys + missing).sort == ids.uniq.sort
        raise CompanyIdentityError.new("Incomplete company batch read response")
      end
      rows =
        companies.map do |requested_id, company|
          scope.merge(
            object: "company",
            external_id: requested_id,
            company_external_id: nil,
            data: company.fetch("properties").slice(*company_properties),
          )
        end
      [rows, missing]
    end

    def recoverable_company_error?(error)
      error.is_a?(CompanyIdentityError) || error.status == 400 ||
        (error.status == 207 && Array(error.diagnostics[:category]).include?("VALIDATION_ERROR"))
    end

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
