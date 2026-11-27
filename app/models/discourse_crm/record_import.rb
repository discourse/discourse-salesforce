# frozen_string_literal: true

module DiscourseCrm
  # Links pulled CRM records to the eligible users whose email they carry, stores their
  # mapped data and fills mapped Discourse fields. Provider importers turn API responses
  # into entries.
  class RecordImport
    # `modified` only orders the records of one provider, so any sortable string works.
    Entry = Data.define(:id, :email, :modified, :properties, :company_id)

    Page =
      Data.define(
        :links,
        :records,
        :removed_user_ids,
        :changed_user_ids,
        :destination_errors,
        :outdated_ids,
      ) do
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
          results
        end
      end

    # Raised when the pull was deleted or its CRM account changed while a page was in flight.
    # Jobs stop without recording a failure.
    class Paused < StandardError
    end

    def initialize(configuration)
      @configuration = configuration
    end

    # Every record the provider returned belongs in `entries`, matched or not, so records
    # that no longer match a user lose their links. `all_user_records` says the entries hold
    # every record of the matched users, as in a single user's pull.
    def store(entries, all_user_records: false)
      @configuration.lock_for_import!
      # Another job may have stored a newer version of a record while this response was in
      # flight; the older response leaves that record and its links alone.
      outdated_ids = outdated_entry_ids(entries)
      entries = entries.reject { |entry| outdated_ids.include?(entry.id) }
      links = []
      records = {}
      modified = {}
      latest = {}
      matches(entries).each do |user_id, entry|
        latest[user_id] = later(latest[user_id], entry)
        links << scope.merge(direction: "inbound", user_id: user_id, external_id: entry.id)
        records[entry.id] ||= scope.merge(
          external_id: entry.id,
          company_external_id: entry.company_id,
          data: entry.properties.slice(*@configuration.record_sources),
        )
        modified[entry.id] ||= modified_time(entry)
      end
      new_links = RecordLink.link_many!(links, returning: %w[external_id])
      changed_ids = Record.store_many!(records.values).to_set
      Record.store_crm_modified!(**scope, modified_by_id: modified)
      new_links.pluck("external_id").each { |id| changed_ids << id }
      removed_users = unlink_stale(entries.map(&:id), links)
      # A user's own pull holds all of their records, unless a newer stored one was kept.
      winners = all_user_records && outdated_ids.empty? ? latest : without_newer_records(latest)
      applied =
        UserSyncDestinations.apply(
          @configuration.destination_mappings,
          winners.transform_values(&:properties),
        )
      changed_users =
        links.filter_map do |link|
          if changed_ids.include?(link[:external_id]) ||
               applied.changed_user_ids.include?(link[:user_id])
            link[:user_id]
          end
        end
      Page.new(links, records, removed_users, changed_users.uniq, applied.errors, outdated_ids)
    end

    # After pulling one user's records, removes the user's links to records not returned.
    def user_reasons(user_id, page)
      kept = page.links.filter_map { |link| link[:external_id] if link[:user_id] == user_id }
      kept += page.outdated_ids
      stale = @configuration.record_links.where(user_id: user_id).where.not(external_id: kept)
      stale_ids = stale.pluck(:external_id)
      if stale_ids.any?
        stale.where(external_id: stale_ids).delete_all
        remove_orphans(stale_ids)
      end
      reasons = page.reasons(also_removed: stale_ids.any? ? [user_id] : [])
      reasons[user_id] ||= "skipped_no_match"
      reasons
    end

    # Unlinks the given users that can no longer be matched, without asking the CRM.
    def unlink_ineligible(user_ids)
      unlinked = []
      RecordLink.transaction do
        @configuration.lock_for_import!
        links =
          @configuration
            .record_links
            .where(user_id: user_ids)
            .where.not(user_id: UserEligibility.eligible_users.select(:id))
        unlinked = links.distinct.pluck(:user_id)
        next if unlinked.empty?
        record_ids = links.distinct.pluck(:external_id)
        links.delete_all
        remove_orphans(record_ids)
        yield unlinked.index_with("contact_unlinked")
      end
      @configuration.evaluate_segments_later(user_ids: unlinked) if unlinked.any?
    end

    private

    # Pairs each eligible user with the entries that carry one of the user's emails.
    def matches(entries)
      by_email =
        entries.select { |entry| entry.email.present? }.group_by { |entry| entry.email.downcase }
      UserEligibility
        .eligible_users
        .with_email(by_email.keys)
        .pluck("users.id", "user_emails.email")
        .flat_map do |user_id, email|
          by_email.fetch(email.downcase).map { |entry| [user_id, entry] }
        end
    end

    # A user's records can arrive on different pages, so a page fills a user's fields only
    # when none of the user's other records changed more recently in the CRM.
    def without_newer_records(latest)
      return latest if latest.empty?
      newest =
        @configuration
          .record_links
          .where(user_id: latest.keys)
          .joins(:record)
          .where.not(crm_records: { crm_modified_at: nil })
          .pluck(:user_id, "crm_records.crm_modified_at", "crm_records.external_id")
          .group_by(&:first)
          .transform_values { |rows| rows.map { |_, time, id| [time, id] }.max }
      latest.reject do |user_id, entry|
        stored = newest[user_id]
        stored && (modified_time(entry).nil? || (stored <=> recency(entry)) == 1)
      end
    end

    # Records modified at the same moment are ordered by id, so the winner does not depend
    # on how the CRM split them into pages.
    def recency(entry)
      [modified_time(entry) || Time.at(0), entry.id]
    end

    def outdated_entry_ids(entries)
      stored =
        @configuration
          .records
          .where(external_id: entries.map(&:id))
          .where.not(crm_modified_at: nil)
          .pluck(:external_id, :crm_modified_at)
          .to_h
      entries.filter_map do |entry|
        time = modified_time(entry)
        entry.id if time && stored[entry.id] && stored[entry.id] > time
      end
    end

    def modified_time(entry)
      Time.zone.parse(entry.modified.to_s)
    rescue ArgumentError
      nil
    end

    def later(current, entry)
      current.nil? || (recency(entry) <=> recency(current)) == 1 ? entry : current
    end

    def unlink_stale(record_ids, links)
      keep = links.to_set { |link| [link[:user_id], link[:external_id]] }
      stale =
        @configuration
          .record_links
          .where(external_id: record_ids)
          .pluck(:id, :user_id, :external_id)
          .reject { |_, user_id, external_id| keep.include?([user_id, external_id]) }
      RecordLink.where(id: stale.map(&:first)).delete_all if stale.any?
      remove_orphans(record_ids)
      stale.map(&:second).uniq
    end

    def remove_orphans(record_ids)
      return if record_ids.empty?
      removed =
        @configuration
          .records
          .where(external_id: record_ids)
          .where
          .missing(:record_links)
          .delete_all
      flow = @configuration.flow
      flow.records_removed(@configuration) if removed > 0 && flow.respond_to?(:records_removed)
    end

    def scope
      @configuration.slice(:provider, :account, :object).symbolize_keys
    end
  end
end
