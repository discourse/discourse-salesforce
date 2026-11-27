# frozen_string_literal: true

module ::Hubspot
  # Stores the companies that pulled contacts point to. A company reaches a user only through
  # a contact, so companies wait for a contact pull before they appear anywhere.
  class CompanyImport
    class CompanyIdentityError < InvalidApiResponse
    end

    Result = Data.define(:changed, :missing)

    MERGED_IDS_PROPERTY = "hs_merged_object_ids"

    def initialize(configuration, api: Api.new)
      if configuration.connection_changed?
        raise Discourse::InvalidParameters.new(:hubspot_portal_id)
      end
      @configuration = configuration
      @api = api
    end

    # Refreshes the companies of one user's freshly pulled contacts, when companies are pulled.
    # Configuration-wide contact pulls leave companies to the company pull's own schedule.
    def self.refresh_later(contacts_configuration, ids, user_id:)
      return if ids.empty?
      pull =
        DiscourseCrm::SyncConfiguration.active.inbound.find_by(
          provider: contacts_configuration.provider,
          account: contacts_configuration.account,
          object: "company",
        )
      return unless pull
      Jobs.enqueue(
        Jobs::Hubspot::PullCompanies,
        configuration_id: pull.id,
        account: pull.account,
        reason: "contacts_pulled",
        company_ids: ids,
        user_id: user_id,
      )
    end

    def referenced_ids(after:, limit: Api::PAGE_SIZE)
      contact_records
        .where.not(company_external_id: nil)
        .where("company_external_id > ?", after)
        .distinct
        .order(:company_external_id)
        .limit(limit)
        .pluck(:company_external_id)
    end

    # A response that cannot be matched to the requested companies is recorded and skipped,
    # so one bad page does not stop the rest of the pull.
    def refresh(ids)
      begin
        rows, missing = fetch_rows(ids)
      rescue InvalidApiResponse => error
        raise unless recoverable?(error)
      end

      DiscourseCrm::Record.transaction do
        # A pull deleted while the request was in flight has already removed its companies.
        @configuration.lock_for_import!
        if error
          DiscourseCrm::SyncAttempt.record(@configuration, nil, error: error)
        else
          # The lock reloaded the mappings, which may have dropped a property meanwhile.
          sources = @configuration.record_sources
          rows = rows.map { |row| row.merge(data: row[:data].slice(*sources)) }
          changed = DiscourseCrm::Record.store_many!(rows)
          @configuration.records.where(external_id: missing).delete_all if missing.any?
          result = Result.new(changed, missing)
        end
        block_given? ? yield(result) : result
      end
    end

    def remove_unreferenced
      self.class.remove_unreferenced(@configuration.account)
    end

    # Removes the given companies, or all of the account's companies, that no contact
    # references any more.
    def self.remove_unreferenced(account, company_ids = nil)
      return if company_ids&.empty?
      scope = { provider: "hubspot", account: }
      referenced =
        DiscourseCrm::Record
          .within(**scope, object: "contact")
          .where.not(company_external_id: nil)
          .select(:company_external_id)
      companies = DiscourseCrm::Record.within(**scope, object: "company")
      companies = companies.where(external_id: company_ids) if company_ids
      companies.where.not(external_id: referenced).delete_all
    end

    # Pulled contacts linked to users, for reporting company changes per user.
    def linked_contacts(company_ids, user_id: nil)
      contacts = contact_records.where(company_external_id: company_ids).joins(:record_links)
      user_id ? contacts.where(crm_record_links: { user_id: }) : contacts
    end

    private

    def contact_records
      DiscourseCrm::Record.within(
        provider: @configuration.provider,
        account: @configuration.account,
        object: "contact",
      )
    end

    def fetch_rows(ids)
      return [], [] if ids.empty?
      properties = @configuration.record_sources | [MERGED_IDS_PROPERTY]
      results, missing = @api.batch_read_companies(ids, properties: properties)
      companies = {}
      results.each do |company|
        id = company.fetch("id")
        aliases = company.fetch("properties")[MERGED_IDS_PROPERTY].to_s.split(";")
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
          {
            provider: @configuration.provider,
            account: @configuration.account,
            object: "company",
            external_id: requested_id,
            company_external_id: nil,
            data: company.fetch("properties").slice(*@configuration.record_sources),
          }
        end
      [rows, missing]
    end

    def recoverable?(error)
      error.is_a?(CompanyIdentityError) || error.status == 400 ||
        (error.status == 207 && Array(error.diagnostics[:category]).include?("VALIDATION_ERROR"))
    end
  end
end
