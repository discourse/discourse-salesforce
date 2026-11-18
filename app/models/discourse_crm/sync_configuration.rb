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

    def self.available_targets
      enabled_providers
        .select(&:credentials?)
        .flat_map do |provider|
          provider
            .flows
            .select { |flow| flow.direction == "outbound" }
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
      transaction do
        record.save!
        if previous_group_ids != new_group_ids
          record.configuration_groups.delete_all
          record.configuration_groups.insert_all(new_group_ids.map { |group_id| { group_id: } })
        end
      end
      ConfigurationScheduler.configuration_saved(
        record,
        group_ids_changed: previous_group_ids != new_group_ids,
      )
      record
    end

    def self.remove!(id, guardian:)
      raise Discourse::InvalidAccess unless guardian.is_admin?

      record = find_by(id: id)
      raise Discourse::NotFound unless record
      record.destroy!
    end

    def self.record_result(id, user_id = nil, error: nil)
      if user_id
        if error
          SyncState.store(id, user_id, error: error.class.name, error_at: Time.zone.now)
        else
          SyncState.where(configuration_id: id, user_id: user_id).update_all(
            error: nil,
            error_at: nil,
          )
          where(id: id).update_all(last_synced_at: Time.zone.now)
          outbound
            .where(id: id)
            .where.not(last_error: nil)
            .update_all(last_error: nil, last_error_at: nil)
        end
      elsif error
        where(id: id).update_all(last_error: error.class.name, last_error_at: Time.zone.now)
      else
        where(id: id).update_all(last_synced_at: Time.zone.now)
      end
    end

    def self.record_batch_failure(id, user_ids, error:)
      ids = Array(user_ids).map(&:to_i).uniq
      return if ids.empty? || ids.size > ConfigurationScheduler::BATCH_SIZE
      ids.each { |user_id| record_result(id, user_id, error: error) }
      record_result(id, error: error)
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
      when "join", "change", "retry"
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
