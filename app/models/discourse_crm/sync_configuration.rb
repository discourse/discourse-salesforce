# frozen_string_literal: true

module DiscourseCrm
  class SyncConfiguration < ActiveRecord::Base
    self.table_name = "crm_sync_configurations"

    PROVIDERS = {
      "salesforce" => ::Salesforce::SyncProvider,
      "hubspot" => ::Hubspot::SyncProvider,
    }.freeze
    SCHEDULES = %w[daily hourly weekly manual].freeze
    MAX_GROUPS = 100
    MAX_MAPPINGS = 50

    has_many :configuration_groups,
             class_name: "DiscourseCrm::SyncConfigurationGroup",
             foreign_key: :configuration_id,
             dependent: :delete_all
    has_many :groups, through: :configuration_groups
    has_many :sync_states,
             class_name: "DiscourseCrm::SyncState",
             foreign_key: :configuration_id,
             dependent: :delete_all
    has_many :record_links,
             class_name: "DiscourseCrm::RecordLink",
             primary_key: %i[provider account object direction],
             foreign_key: %i[provider account object direction]
    has_many :records,
             class_name: "DiscourseCrm::Record",
             primary_key: %i[provider account object],
             foreign_key: %i[provider account object]
    has_many :segments,
             class_name: "DiscourseCrm::Segment",
             foreign_key: :configuration_id,
             dependent: :destroy

    # Serialize dependent deletion with workers inserting sync states.
    before_destroy(prepend: true) { self.class.where(id: id).lock.pick(:id) }
    after_destroy { flow.removed(self) if flow.respond_to?(:removed) }

    enum :direction, { outbound: "outbound", inbound: "inbound" }, validate: true

    validates :provider, inclusion: { in: PROVIDERS.keys }
    validates :name, presence: true, length: { maximum: 60 }
    validates :schedule, inclusion: { in: SCHEDULES }
    validates :account,
              uniqueness: {
                scope: %i[provider object],
                conditions: -> { inbound },
              },
              if: :inbound?
    validate :provider_shape
    validate :mappings_shape

    # Pulls that match records to users, which segments can build on.
    scope :user_pulls, -> { inbound.where(kind: "users") }

    scope :for_provider,
          ->(name) { where(provider: name, account: self.provider_definition(name).account) }

    def self.provider_definition(name)
      PROVIDERS.fetch(name)
    end

    def self.enabled_providers
      PROVIDERS.values.select(&:enabled?)
    end

    def self.available_providers
      enabled_providers.map do |provider|
        { name: provider.key, credentials_configured: provider.credentials? }
      end
    end

    def self.available_targets(direction = "outbound")
      enabled_providers
        .select(&:credentials?)
        .flat_map do |provider|
          provider
            .flows
            .select { |flow| flow.direction == direction }
            .flat_map do |flow|
              flow.objects.map { |object| { provider: provider.key, object: object } }
            end
        end
    end

    def self.enabled?
      enabled_providers.any?
    end

    def self.active
      enabled = enabled_providers
      return none if enabled.empty?
      where(active: true).merge(
        enabled.map { |definition| for_provider(definition.key) }.reduce(:or),
      )
    end

    def self.available_groups(query: nil)
      groups = Group.where.not(id: Group::AUTO_GROUPS[:everyone])
      if query.present?
        pattern = "%#{Group.sanitize_sql_like(query.to_s.first(100))}%"
        groups = groups.where("name ILIKE ?", pattern)
      end
      counts =
        GroupUser
          .where(
            group_id: groups.select(:id),
            user_id: DiscourseCrm::UserEligibility.eligible_users.select(:id),
          )
          .group(:group_id)
          .count
      groups
        .order(:name)
        .pluck(:id, :name)
        .map { |id, name| { id: id, name: name, user_count: counts.fetch(id, 0) } }
    end

    def self.resolve_groups!(ids)
      unless ids.is_a?(Array) && ids.present? && ids.size <= MAX_GROUPS &&
               ids.all? { |id| id.to_s.match?(/\A\d+\z/) }
        raise Discourse::InvalidParameters.new(:group_ids)
      end
      ids = ids.map(&:to_i).uniq
      groups = Group.where.not(id: Group::AUTO_GROUPS[:everyone]).where(id: ids).to_a
      raise Discourse::InvalidParameters.new(:group_ids) if groups.size != ids.size
      groups
    end

    def self.create_or_update!(params, id:, guardian:)
      raise Discourse::InvalidAccess unless guardian.is_admin?

      params = params.deep_stringify_keys
      definition = PROVIDERS[params["provider"]]
      raise Discourse::InvalidParameters.new(:provider) unless definition&.enabled?
      %w[direction kind].each do |attribute|
        raise Discourse::InvalidParameters.new(attribute.to_sym) if params[attribute].blank?
      end
      flow = definition.flow(params["direction"], params["kind"])
      unless flow
        if definition.flows.none? { |candidate| candidate.direction == params["direction"] }
          raise Discourse::InvalidParameters.new(:direction)
        end
        raise Discourse::InvalidParameters.new(:kind)
      end
      if flow.requires_groups?
        groups = resolve_groups!(params["group_ids"])
      else
        raise Discourse::InvalidParameters.new(:group_ids) if params["group_ids"].present?
        groups = []
      end

      record = id ? find_by(id: id) : new(provider: definition.key, direction: params["direction"])
      raise Discourse::NotFound if id && !record
      if record.persisted?
        %w[provider direction kind object].each do |attribute|
          if record.public_send(attribute) != params[attribute]
            raise Discourse::InvalidParameters.new(attribute.to_sym)
          end
        end
      end
      record.assign_attributes(
        name: params["name"],
        kind: params["kind"],
        object: params["object"],
        schedule: params["schedule"],
        backfill: ActiveModel::Type::Boolean.new.cast(params["backfill"]),
        mappings: params["mappings"],
        active: true,
      )
      record.account = definition.account
      raise Discourse::InvalidParameters.new(:configuration) if record.invalid?

      flow.validate_mappings!(record)
      record.account = definition.account

      previous_group_ids = record.persisted? ? record.group_ids.sort : []
      new_group_ids = groups.map(&:id).sort
      # Serialize saves so two configurations cannot each pass the loop check and together form a loop.
      DistributedMutex.synchronize("discourse_crm_sync_configuration_mappings") do
        MappingGraph.validate!(record)
        transaction do
          record.save!
          if previous_group_ids != new_group_ids
            record.configuration_groups.delete_all
            record.configuration_groups.insert_all(new_group_ids.map { |group_id| { group_id: } })
          end
        end
      end
      ConfigurationScheduler.configuration_saved(
        record,
        group_ids_changed: previous_group_ids != new_group_ids,
      )
      record
    rescue InvalidMapping => error
      error.locate(record.mappings) if record
      raise
    end

    def self.remove!(id, guardian:)
      raise Discourse::InvalidAccess unless guardian.is_admin?

      record = find_by(id: id)
      raise Discourse::NotFound unless record
      record.destroy!
    end

    def self.record_result(id, ...)
      find_by(id: id)&.record_result(...)
    end

    def record_result(
      user_id = nil,
      error: nil,
      reason: nil,
      record_attempt: true,
      summarize_repeat: false
    )
      self.class.transaction do
        if user_id
          if error
            SyncState.store(id, user_id, error: error.class.name, error_at: Time.zone.now)
          else
            self.class.where(id: id).update_all(last_synced_at: Time.zone.now)
            self
              .class
              .outbound
              .where(id: id)
              .where.not(last_error: nil)
              .update_all(last_error: nil, last_error_at: nil)
            cleared_errors =
              SyncState
                .where(configuration_id: id, user_id: user_id)
                .where.not(error: nil)
                .update_all(error: nil, error_at: nil)
            if cleared_errors.zero? && (reason == "unchanged" || summarize_repeat)
              last_outcome, last_reason =
                SyncAttempt
                  .where(configuration_id: id, user_id: user_id)
                  .order(created_at: :desc, id: :desc)
                  .pick(:outcome, :reason)
              if last_outcome != "failed" && (reason == "unchanged" || reason == last_reason)
                next reason.to_sym
              end
            end
          end
        elsif error
          self
            .class
            .where(id: id)
            .update_all(last_error: error.class.name, last_error_at: Time.zone.now)
        else
          self.class.where(id: id).update_all(last_synced_at: Time.zone.now)
        end
        SyncAttempt.record(self, user_id, error: error, reason: reason) if record_attempt
      end
    end

    def record_import_results(
      reasons,
      clear_errors_for: reasons.keys,
      scheduled_at: nil,
      errors: {}
    )
      # A user whose pulled value Discourse rejected is reported as failed, not as unchanged.
      reasons = reasons.reject { |user_id, reason| reason == "unchanged" && errors.key?(user_id) }
      self.class.transaction do
        unchanged = reasons.select { |_, reason| reason == "unchanged" }.keys
        if unchanged.any?
          recovering = sync_states.where(user_id: unchanged).where.not(error: nil).pluck(:user_id)
          unchanged -= recovering
          unchanged -= SyncAttempt.users_with_latest_failure(id, unchanged)
          if unchanged.any?
            SyncAttempt.record_check_summary(
              self,
              scheduled_at,
              unchanged.size,
              reason: "unchanged_summary",
            )
          end
        end
        reasons
          .except(*unchanged)
          .each { |user_id, reason| SyncAttempt.record(self, user_id, reason: reason) }
        sync_states.where(user_id: Array(clear_errors_for) - errors.keys).update_all(
          error: nil,
          error_at: nil,
        )
        errors.each { |user_id, error| record_result(user_id, error: error) }
      end
    end

    # Ends a configuration-wide pull. A run that recorded no per-user history still leaves
    # one attempt, so the activity log shows that it ran.
    def finish_pull(started_at, history_result, empty_reason: "no_contacts")
      SyncAttempt.transaction do
        if history_result != "recorded"
          SyncAttempt.record(self, nil, reason: history_result || empty_reason)
        end
        self
          .class
          .where(id: id)
          .where("last_synced_at IS NULL OR last_synced_at < ?", started_at)
          .update_all(last_synced_at: started_at, last_error: nil, last_error_at: nil)
      end
      evaluate_segments_later
    end

    # Locks the pull for one page's writes. Pages of the same pull take turns, which also lets
    # them update shared summaries without deadlocking. Deleting the pull or its last group
    # waits for the page, and a page that starts afterwards finds the pull gone or paused.
    # Also reloads the configuration, so a page writes with the mappings saved right now
    # rather than those loaded before its CRM request. A response fetched from a CRM account
    # the pull no longer uses is dropped.
    def lock_for_import!
      fetched_from = account
      reload(lock: "FOR NO KEY UPDATE")
      raise RecordImport::Paused if !active || account != fetched_from
    rescue ActiveRecord::RecordNotFound
      raise RecordImport::Paused
    end

    # Segments belong to user pulls and also read the companies a company pull stores, so a
    # company pull re-evaluates the segments of its provider's user pulls.
    def evaluate_segments_later(user_ids: nil)
      return unless SiteSetting.crm_segments_enabled
      pull_ids =
        if kind == "users"
          [id]
        else
          self.class.active.user_pulls.where(provider:, account:).pluck(:id)
        end
      pull_ids.each do |pull_id|
        Jobs.enqueue(
          Jobs::DiscourseCrm::EvaluateSegments,
          { configuration_id: pull_id, user_ids: }.compact,
        )
      end
    end

    def self.record_batch_failure(id, ...)
      find_by(id: id)&.record_batch_failure(...)
    end

    def record_batch_failure(user_ids, error:)
      ids = Array(user_ids).map(&:to_i).uniq
      return if ids.empty? || ids.size > ConfigurationScheduler::BATCH_SIZE
      failures = block_given? ? ids.group_by { |user_id| yield(user_id) } : { error => ids }
      self.class.transaction do
        record_result(error: error, record_attempt: false)
        failures.each do |failure, affected_ids|
          SyncState.store(id, affected_ids, error: failure.class.name, error_at: Time.zone.now)
          user_id = affected_ids.first if affected_ids.one?
          SyncAttempt.record(self, user_id, error: failure)
        end
      end
    end

    def self.record_batch_success(id)
      where(id: id).update_all(last_error: nil, last_error_at: nil)
    end

    def provider_definition
      PROVIDERS[provider]
    end

    def flow
      provider_definition&.flow(direction, kind)
    end

    def reason_enabled?(reason)
      case reason
      when "join", "change", "retry", "contacts_pulled"
        true
      when "backfill"
        backfill
      when "scheduled"
        schedule != "manual"
      else
        false
      end
    end

    def connection_changed?
      account != provider_definition.account
    end

    # The CRM fields kept in this configuration's stored records.
    def record_sources
      mappings.filter_map { |mapping| mapping["source"] if (mapping["object"] || object) == object }
    end

    def destination_mappings
      mappings.select { |mapping| mapping["destination"].present? }
    end

    # Segments match on a user's records and the companies those records point to, so a user
    # pull also offers the properties its provider's company pull stores.
    def pulled_properties
      pulls = [self]
      if kind == "users"
        pulls += self.class.active.inbound.where(provider:, account:, kind: "companies").to_a
      end
      pulls
        .flat_map(&:mappings)
        .map { |mapping| { object: mapping["object"], name: mapping["source"] } }
        .uniq
    end

    def record_link_for(user_id)
      record_links.find_by(user_id:)
    end

    def sync_status
      status = { "last_synced_at" => last_synced_at&.utc&.iso8601 }
      error_name, error_at = last_error ? [last_error, last_error_at] : first_user_error
      if error_name
        status["error"] = error_name
        status["last_error_at"] = error_at&.utc&.iso8601
      end
      status
    end

    private

    def first_user_error
      users =
        (
          if inbound?
            DiscourseCrm::UserEligibility.eligible_users
          else
            DiscourseCrm::UserEligibility.eligible_group_members(group_ids)
          end
        )
      sync_states
        .where.not(error: nil)
        .where(user_id: users.select(:id))
        .order(:error_at, :id)
        .pick(:error, :error_at)
    end

    def provider_shape
      definition = provider_definition
      return unless definition
      if definition.flows.none? { |candidate| candidate.direction == direction }
        errors.add(:direction, :invalid)
      elsif flow.nil?
        errors.add(:kind, :invalid)
      elsif flow.objects.exclude?(object)
        errors.add(:object, :invalid)
      end
    end

    def mappings_shape
      if mappings.is_a?(Array) && mappings.size <= MAX_MAPPINGS &&
           mappings.all? { |mapping| mapping.is_a?(Hash) }
        return
      end
      errors.add(:mappings, :invalid)
    end
  end
end

# == Schema Information
#
# Table name: crm_sync_configurations
#
#  id                :bigint           not null, primary key
#  account           :string           not null
#  active            :boolean          default(TRUE), not null
#  backfill          :boolean          default(FALSE), not null
#  direction         :string           not null
#  kind              :string           default("users"), not null
#  last_error        :string
#  last_error_at     :datetime
#  last_scheduled_at :datetime
#  last_synced_at    :datetime
#  mappings          :jsonb            not null
#  name              :string           not null
#  object            :string           not null
#  provider          :string           not null
#  schedule          :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#
#  index_crm_sync_configurations_on_inbound_scope         (provider,account,object) UNIQUE WHERE ((direction)::text = 'inbound'::text)
#  index_crm_sync_configurations_on_provider_and_account  (provider,account)
#
