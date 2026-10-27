# frozen_string_literal: true

module Salesforce
  class UserSyncSources
    PROFILE_COLUMNS = { "bio" => :bio_raw, "website" => :website }.freeze

    STAT_COLUMNS = {
      "posts" => :post_count,
      "read_time" => :time_read,
      "posts_read" => :posts_read_count,
      "topics_entered" => :topics_entered,
      "likes_given" => :likes_given,
      "likes_received" => :likes_received,
      "days_visited" => :days_visited,
    }.freeze

    def self.custom_sources
      UserField
        .order(:position, :id)
        .map do |field|
          {
            id: "user_field_#{field.id}",
            name: field.name.presence || field.description,
            type:
              case field.field_type
              when "confirm"
                "boolean"
              when "date"
                "date"
              else
                "text"
              end,
          }
        end
    end

    def initialize(mappings, users)
      sources = mappings.map { |mapping| mapping["source"] }
      profile_columns = sources.filter_map { |source| PROFILE_COLUMNS[source] }.uniq
      @profiles =
        if profile_columns.empty?
          {}
        else
          UserProfile
            .where(user_id: users.map(&:id))
            .pluck(:user_id, *profile_columns)
            .to_h { |user_id, *values| [user_id, profile_columns.zip(values).to_h] }
        end
      columns = sources.filter_map { |source| STAT_COLUMNS[source] }.uniq
      @stats =
        if columns.empty?
          {}
        else
          UserStat
            .where(user_id: users.map(&:id))
            .pluck(:user_id, *columns)
            .to_h { |user_id, *values| [user_id, columns.zip(values).to_h] }
        end
      ids =
        sources.filter_map { |source| /\Auser_field_(\d+)\z/.match(source.to_s)&.captures&.first }
      @field_types =
        UserField
          .where(id: ids)
          .pluck(:id, :field_type)
          .to_h
          .transform_keys { |id| "user_field_#{id}" }
      @custom_values = User.custom_fields_for_ids(users.map(&:id), @field_types.keys)
    end

    def value(source, user)
      if column = PROFILE_COLUMNS[source]
        return @profiles.dig(user.id, column).presence
      end
      if column = STAT_COLUMNS[source]
        value = @stats.dig(user.id, column) || 0
        return source == "read_time" ? (value / 60.0).round(2) : value
      end

      type = @field_types[source]
      raise Discourse::InvalidParameters.new(:source) unless type
      value = @custom_values.dig(user.id, source)
      return nil if value.nil? || value == ""

      case type
      when "confirm"
        HasCustomFields::Helpers::CUSTOM_FIELD_TRUE.include?(value)
      when "date"
        Date.iso8601(value)
      else
        value
      end
    rescue Date::Error
      raise Discourse::InvalidParameters.new(:user_fields)
    end
  end
end
