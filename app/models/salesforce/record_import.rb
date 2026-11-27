# frozen_string_literal: true

module ::Salesforce
  # Pulls the Leads or Contacts of one configuration. Pages are ordered by modification
  # time and Id, and each page continues after the last record it returned, so a long
  # pull has no query cursor that could expire between jobs.
  class RecordImport
    PAGE_SIZE = 200
    MODIFIED_FIELD = "SystemModstamp"

    # `last` is false while Salesforce may hold more records; it can return fewer than
    # PAGE_SIZE records in a batch and report the rest through `done`.
    Batch = Data.define(:records, :last)

    def initialize(configuration, api: Api.new)
      if configuration.connection_changed?
        raise Discourse::InvalidParameters.new(:salesforce_instance_url)
      end
      @configuration = configuration
      @api = api
      @records = DiscourseCrm::RecordImport.new(configuration)
    end

    # Records modified at or after `since`, continuing after the `after` cursor.
    def fetch_page(since: nil, after: nil)
      conditions = []
      conditions << "#{MODIFIED_FIELD} >= #{soql_time(since)}" if since
      if after
        modified, id = after
        conditions << "(#{MODIFIED_FIELD} > #{soql_time(modified)} OR " \
          "(#{MODIFIED_FIELD} = #{soql_time(modified)} AND Id > #{quoted(id)}))"
      end
      result =
        @api.query(
          "#{select} #{where(conditions)}ORDER BY #{MODIFIED_FIELD}, Id LIMIT #{PAGE_SIZE}",
        )
      records = result.fetch("records")
      last = records.empty? || (result["done"] != false && records.size < PAGE_SIZE)
      Batch.new(records:, last:)
    end

    def cursor(records)
      last = records.last
      [last.fetch(MODIFIED_FIELD), last.fetch("Id")]
    end

    def import_page(records, all_user_records: false)
      DiscourseCrm::Record.transaction do
        page = @records.store(records.map { |record| entry(record) }, all_user_records:)
        block_given? ? yield(page) : page
      end
    end

    def import_user(user)
      emails = user.emails.map { |email| quoted(email) }.join(",")
      # Every match is needed, since links to records not returned are removed.
      records = @api.query_all("#{select} WHERE Email IN (#{emails})")
      import_page(records, all_user_records: true) do |page|
        reasons = @records.user_reasons(user.id, page)
        yield reasons, page if block_given?
        reasons
      end
    end

    private

    # A converted Lead lives on as a Contact, so it no longer matches anyone here.
    def entry(record)
      DiscourseCrm::RecordImport::Entry.new(
        id: record.fetch("Id"),
        email: record["IsConverted"] ? nil : record["Email"],
        modified: record[MODIFIED_FIELD],
        properties: record.except("attributes"),
        company_id: nil,
      )
    end

    def select
      fields = ["Id", "Email", MODIFIED_FIELD, *@configuration.record_sources]
      fields << "IsConverted" if @configuration.object == "Lead"
      "SELECT #{fields.uniq.join(", ")} FROM #{@configuration.object}"
    end

    def where(conditions)
      conditions.empty? ? "" : "WHERE #{conditions.join(" AND ")} "
    end

    def soql_time(value)
      Time.zone.parse(value.to_s).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def quoted(value)
      "'#{Person.escape_soql_string(value)}'"
    end
  end
end
