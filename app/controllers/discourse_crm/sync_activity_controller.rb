# frozen_string_literal: true

module DiscourseCrm
  class SyncActivityController < ::Admin::AdminController
    requires_plugin ::Salesforce::PLUGIN_NAME
    include GuidedSyncEndpoint
    prepend_before_action :redirect_disabled_activity_page, only: :index

    PAGE_SIZE = 50

    def index
      render html: "", layout: "admin"
    end

    def attempts
      records =
        SyncAttempt.includes(:configuration, user: :user_emails).order(created_at: :desc, id: :desc)
      %i[outcome provider].each do |key|
        next if params[key].blank?
        allowed = key == :outcome ? SyncAttempt::OUTCOMES : SyncConfiguration::PROVIDERS.keys
        raise Discourse::InvalidParameters.new(key) if allowed.exclude?(params[key])
        records = records.where(key => params[key])
      end
      if params[:username].present?
        raise Discourse::InvalidParameters.new(:username) unless params[:username].is_a?(String)
        records =
          records.where(
            user_id:
              User.where(username_lower: User.normalize_username(params[:username])).select(:id),
          )
      end
      from = parse_date(:from)
      to = parse_date(:to)
      raise Discourse::InvalidParameters.new(:to) if from && to && from >= to
      records = records.where("created_at >= ?", from) if from
      records = records.where("created_at < ?", to) if to
      if params[:before].present?
        records =
          records.where(
            "(crm_sync_attempts.created_at, crm_sync_attempts.id) < (?, ?)",
            *pagination_cursor,
          )
      end
      page = records.limit(PAGE_SIZE + 1).to_a
      more = page.size > PAGE_SIZE
      page = page.first(PAGE_SIZE)
      render json: {
               attempts: serialize_data(page, SyncAttemptSerializer),
               next_before: more ? "#{page.last.created_at.utc.iso8601(6)}|#{page.last.id}" : nil,
             }
    end

    private

    def redirect_disabled_activity_page
      if request.format.html? && current_user&.admin? &&
           !Discourse.plugins_by_name.fetch(::Salesforce::PLUGIN_NAME).enabled?
        redirect_to path("/admin/plugins/discourse-salesforce/settings")
      end
    end

    def pagination_cursor
      timestamp, id = params[:before].to_s.split("|", 2)
      raise Discourse::InvalidParameters.new(:before) unless id&.match?(/\A[1-9]\d*\z/)
      [Time.iso8601(timestamp), id.to_i]
    rescue ArgumentError
      raise Discourse::InvalidParameters.new(:before)
    end

    def parse_date(key)
      return if params[key].blank?
      value = params[key].to_s
      if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        date = Date.iso8601(value)
        zone = Time.find_zone(params[:timezone].to_s.presence || "UTC")
        raise Discourse::InvalidParameters.new(:timezone) unless zone
        return (key == :to ? date.next_day : date).in_time_zone(zone)
      end
      unless value.match?(/(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/)
        raise Discourse::InvalidParameters.new(key)
      end
      DateTime.iso8601(value).to_time.utc
    rescue ArgumentError
      raise Discourse::InvalidParameters.new(key)
    end
  end
end
