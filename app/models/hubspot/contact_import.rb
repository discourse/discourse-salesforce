# frozen_string_literal: true

module ::Hubspot
  # Pulls HubSpot contacts. Each stored contact keeps its primary company's ID, which a
  # company pull uses to find the companies to store.
  class ContactImport
    def initialize(configuration, api: Api.new)
      if configuration.connection_changed?
        raise Discourse::InvalidParameters.new(:hubspot_portal_id)
      end
      @configuration = configuration
      @api = api
      @records = DiscourseCrm::RecordImport.new(configuration)
    end

    def requested_properties
      fields =
        @configuration.record_sources.flat_map { |source| InboundUsersFlow.source_fields(source) }
      ["email", Api::LAST_MODIFIED_PROPERTY, Api::COMPANY_PROPERTY, *fields].uniq
    end

    def import_page(contacts, all_user_records: false)
      DiscourseCrm::Record.transaction do
        entries = contacts.map { |contact| entry(contact) }
        previous_companies = stored_company_ids(entries.map(&:id))
        page = @records.store(entries, all_user_records:)
        # A contact that moved to another company can leave its old company unreferenced.
        CompanyImport.remove_unreferenced(@configuration.account, previous_companies)
        block_given? ? yield(page) : page
      end
    end

    def import_user(user)
      contacts = @api.batch_read_contacts_by_email(user.emails, properties: requested_properties)
      company_ids = []
      reasons =
        import_page(contacts, all_user_records: true) do |page|
          company_ids = page.records.values.filter_map { |record| record[:company_external_id] }
          reasons = @records.user_reasons(user.id, page)
          yield reasons, page if block_given?
          reasons
        end
      # Enqueued after the contacts commit, so the company pull can see who they belong to.
      CompanyImport.refresh_later(@configuration, company_ids.uniq, user_id: user.id)
      reasons
    end

    private

    def stored_company_ids(contact_ids)
      @configuration
        .records
        .where(external_id: contact_ids)
        .where.not(company_external_id: nil)
        .distinct
        .pluck(:company_external_id)
    end

    def entry(contact)
      properties = InboundUsersFlow.with_full_name(contact.fetch("properties"))
      DiscourseCrm::RecordImport::Entry.new(
        id: contact.fetch("id"),
        email: properties["email"],
        modified: properties[Api::LAST_MODIFIED_PROPERTY],
        properties: properties,
        company_id: properties[Api::COMPANY_PROPERTY].presence,
      )
    end
  end
end
