# frozen_string_literal: true

module Salesforce
  class GuidedSyncConfiguration < ActiveRecord::Base
    self.table_name = "crm_sync_configurations"

    PROVIDER = "salesforce"
    KINDS = %w[users].freeze
    OBJECTS = %w[Lead Contact].freeze
    SCHEDULES = %w[daily hourly weekly manual].freeze
    MAX_GROUPS = 100
    MAX_MAPPINGS = 50

    has_many :configuration_groups,
             class_name: "Salesforce::GuidedSyncConfigurationGroup",
             foreign_key: :configuration_id,
             dependent: :delete_all
    has_many :groups, through: :configuration_groups
    has_many :sync_states,
             class_name: "Salesforce::SyncState",
             foreign_key: :configuration_id,
             dependent: :delete_all

    validates :provider, inclusion: { in: [PROVIDER] }
    validates :name, presence: true, length: { maximum: 60 }
    validates :kind, inclusion: { in: KINDS }
    validates :object, inclusion: { in: OBJECTS }
    validates :schedule, inclusion: { in: SCHEDULES }
    validate :mappings_shape

    scope :for_current_account,
          -> { where(provider: PROVIDER, account: SiteSetting.salesforce_instance_url) }

    def self.enabled?
      SiteSetting.salesforce_enabled && SiteSetting.enable_guided_sync_configuration
    end

    def self.active
      return none unless enabled?
      where(active: true, kind: "users").for_current_account
    end

    def self.available_groups(query: nil)
      groups = Group.where.not(id: Group::AUTO_GROUPS[:everyone])
      if query.present?
        pattern = "%#{Group.sanitize_sql_like(query.to_s.first(100))}%"
        groups = groups.where("name ILIKE ?", pattern)
      end
      counts =
        GroupUser
          .where(group_id: groups.select(:id), user_id: Person.eligible_users.select(:id))
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
      provider = params.fetch("provider", PROVIDER)
      raise Discourse::InvalidParameters.new(:provider) if provider != PROVIDER
      groups = resolve_groups!(params["group_ids"])

      record = id ? find_by(id: id) : new(provider: PROVIDER)
      raise Discourse::NotFound if id && !record
      if record.persisted? && record.object != params["object"]
        raise Discourse::InvalidParameters.new(:object)
      end
      record.assign_attributes(
        name: params["name"],
        kind: params.fetch("kind", "users"),
        object: params["object"],
        schedule: params["schedule"],
        backfill: ActiveModel::Type::Boolean.new.cast(params["backfill"]),
        mappings: params["mappings"],
        active: true,
      )
      raise Discourse::InvalidParameters.new(:configuration) if record.invalid?

      ConfiguredUserSync.validate_mappings!(
        record,
        Api.cached_writable_fields(record.object, refresh: true),
      )
      record.account = SiteSetting.salesforce_instance_url

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
        end
      elsif error
        where(id: id).update_all(last_error: error.class.name, last_error_at: Time.zone.now)
      else
        where(id: id).update_all(last_synced_at: Time.zone.now)
      end
    end

    def self.record_batch_success(id)
      where(id: id).update_all(last_error: nil, last_error_at: nil)
    end

    def reason_enabled?(reason)
      case reason
      when "join", "change"
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
      account != SiteSetting.salesforce_instance_url
    end

    def record_links
      RecordLink.within(provider:, account:, object:)
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
      sync_states
        .where.not(error: nil)
        .where(user_id: Person.eligible_group_members(group_ids).select(:id))
        .order(:error_at, :id)
        .pick(:error, :error_at)
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
