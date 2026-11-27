# frozen_string_literal: true

module DiscourseCrm
  class SyncAttempt < ActiveRecord::Base
    self.table_name = "crm_sync_attempts"

    OUTCOMES = %w[success failed skipped].freeze
    belongs_to :user, optional: true
    belongs_to :configuration, class_name: "DiscourseCrm::SyncConfiguration", optional: true

    def self.record(configuration, user_id, error: nil, reason: nil)
      transaction do
        create!(
          configuration_id: configuration.id,
          user_id: user_id,
          provider: configuration.provider,
          direction: configuration.direction,
          object: configuration.object,
          outcome: error ? "failed" : outcome_for_reason(reason),
          reason: reason || (error ? "failed" : "synced"),
          error_class: error&.class&.name,
          diagnostics: error_details(error, user_id),
        )
      end
    end

    def self.users_with_latest_failure(configuration_id, user_ids)
      where(configuration_id: configuration_id, user_id: user_ids)
        .order(:user_id, created_at: :desc, id: :desc)
        .pluck(Arel.sql("DISTINCT ON (user_id) user_id"), :outcome)
        .filter_map { |user_id, outcome| user_id if outcome == "failed" }
    end

    def self.track_batch(configuration, pending_ids, scheduled_at)
      counts = Hash.new(0)
      processed =
        lambda do |user_id, result = nil|
          pending_ids.delete(user_id)
          counts[result] += 1 if %i[unchanged skipped_converted].include?(result)
        end
      yield processed
    ensure
      if scheduled_at
        counts.each do |reason, count|
          record_check_summary(configuration, scheduled_at, count, reason: "#{reason}_summary")
        end
      end
    end

    def self.record_check_summary(configuration, scheduled_at, count, reason:)
      transaction do
        # Parallel pages from the same scheduled run contribute to one row.
        next unless SyncConfiguration.where(id: configuration.id).lock.pick(:id)
        summary =
          find_or_initialize_by(
            configuration_id: configuration.id,
            created_at: scheduled_at,
            reason: reason,
          )
        summary.update!(
          provider: configuration.provider,
          direction: configuration.direction,
          object: configuration.object,
          outcome: outcome_for_reason(reason),
          diagnostics: {
            "count" => summary.diagnostics.fetch("count", 0) + count,
          },
        )
      end
    end

    def self.outcome_for_reason(reason)
      reason&.start_with?("skipped_") ? "skipped" : "success"
    end
    private_class_method :outcome_for_reason

    def self.scrub_rejected_values(user_id, email: nil)
      attempts = where(user_id: user_id).where("diagnostics ? 'rejected_values'")
      if email
        attempts =
          attempts.where("lower(diagnostics #>> '{rejected_values,0,value}') = ?", email.downcase)
      end
      attempts.update_all("diagnostics = diagnostics - 'rejected_values'")
    end

    def self.diagnostic_identifiers(values)
      Array(values).grep(String).select { |value| value.match?(/\A[\w.-]{1,100}\z/) }.uniq.first(20)
    end

    def self.error_details(error, user_id)
      return {} unless error
      details = {}
      details[:status] = error.status if error.respond_to?(:status) && error.status.is_a?(Integer)
      return details unless error.respond_to?(:sync_activity_diagnostics)

      diagnostics = error.sync_activity_diagnostics
      %i[codes category properties].each do |key|
        identifiers = diagnostic_identifiers(diagnostics[key])
        details[key] = identifiers if identifiers.any?
      end
      # Destination ids can hold custom field names, which may contain spaces.
      destinations =
        Array(diagnostics[:destinations])
          .grep(String)
          .select { |value| value.length <= 200 && !value.match?(/[[:cntrl:]]/) }
          .uniq
          .first(20)
      details[:destinations] = destinations if destinations.any?
      email = diagnostics[:rejected_email]
      # Hold the email row until the attempt commits so anonymization or deletion scrubs it afterward.
      if email.is_a?(String) && email.length <= 320 && !email.match?(/[[:cntrl:]]/) &&
           UserEmail
             .where(user_id: user_id)
             .where("lower(email) = ?", email.downcase)
             .lock("FOR SHARE")
             .pick(:id)
        details[:rejected_values] = [{ property: "email", value: email }]
      end
      details
    end
  end
end

# == Schema Information
#
# Table name: crm_sync_attempts
#
#  id               :bigint           not null, primary key
#  diagnostics      :jsonb            not null
#  direction        :string           not null
#  error_class      :string
#  object           :string           not null
#  outcome          :string           not null
#  provider         :string           not null
#  reason           :string           not null
#  created_at       :datetime         not null
#  configuration_id :bigint
#  user_id          :integer
#
# Indexes
#
#  index_crm_sync_attempts_on_created_at_and_id               (created_at,id)
#  index_crm_sync_attempts_on_outcome_and_created_at_and_id   (outcome,created_at,id)
#  index_crm_sync_attempts_on_provider_and_created_at_and_id  (provider,created_at,id)
#  index_crm_sync_attempts_on_user_id_and_created_at_and_id   (user_id,created_at,id)
#
