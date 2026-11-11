# frozen_string_literal: true

module Salesforce
  class UserSyncSources
    SOURCE_TYPES = {
      "first" => "text",
      "last" => "text",
      "profile" => "text",
      "bio" => "text",
      "website" => "text",
      "posts" => "number",
      "posts30" => "number",
      "posts_read" => "number",
      "posts_read30" => "number",
      "likes_given" => "number",
      "likes_given30" => "number",
      "likes_received" => "number",
      "trust" => "number",
      "groups" => "text",
      "seen" => "date",
      "first_seen" => "date",
      "static" => "text",
      "custom_field" => "text",
    }.freeze

    CUSTOM_FIELD_KEY_PREFIX = "custom_field:"
    CUSTOM_FIELD_NAME_MAX_LENGTH = 256
    CUSTOM_FIELD_NAMES_LIMIT = 200

    PROFILE_COLUMNS = { "bio" => :bio_raw, "website" => :website }.freeze

    STAT_COLUMNS = {
      "posts" => :post_count,
      "posts_read" => :posts_read_count,
      "likes_given" => :likes_given,
      "likes_received" => :likes_received,
    }.freeze

    # Sources are looked up by key; a custom_field mapping is keyed by the field it reads.
    def self.key(mapping)
      source = mapping["source"]
      source == "custom_field" ? "#{CUSTOM_FIELD_KEY_PREFIX}#{mapping["value"]}" : source
    end

    def self.custom_field_name(key)
      if key.to_s.start_with?(CUSTOM_FIELD_KEY_PREFIX)
        key.to_s.delete_prefix(CUSTOM_FIELD_KEY_PREFIX)
      end
    end

    # Admin user fields are listed through custom_sources, so their storage keys are left out.
    def self.custom_field_names
      UserCustomField
        .where("TRIM(name) <> ''")
        .where.not("name LIKE ?", "#{UserCustomField.sanitize_sql_like("user_field_")}%")
        .distinct
        .order(:name)
        .limit(CUSTOM_FIELD_NAMES_LIMIT)
        .pluck(:name)
    end

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
      sources = mappings.map { |mapping| self.class.key(mapping) }
      user_ids = users.map(&:id)
      @recent_reads =
        if sources.include?("posts_read30")
          UserVisit
            .where(user_id: user_ids)
            .where("visited_at >= ?", Date.current - 29)
            .group(:user_id)
            .sum(:posts_read)
        end
      @recent_likes =
        if sources.include?("likes_given30")
          UserAction
            .joins(target_post: :topic)
            .where(user_id: user_ids, action_type: UserAction::LIKE)
            .where(
              posts: {
                deleted_at: nil,
              },
              topics: {
                deleted_at: nil,
                archetype: Archetype.default,
              },
            )
            .where("user_actions.created_at >= ?", 30.days.ago)
            .group(:user_id)
            .count
        end
      @recent_posts =
        if sources.include?("posts30")
          Post
            .joins(:topic)
            .where(topics: { archetype: Archetype.default })
            .where(user_id: user_ids, post_type: Post.types[:regular])
            .where("posts.created_at >= ?", 30.days.ago)
            .group(:user_id)
            .count
        end
      @groups =
        if sources.include?("groups")
          GroupUser
            .joins(:group)
            .where(user_id: user_ids)
            .order("groups.name")
            .pluck(:user_id, "groups.name")
            .group_by(&:first)
        end
      profile_columns = sources.filter_map { |source| PROFILE_COLUMNS[source] }.uniq
      @profiles =
        if profile_columns.empty?
          {}
        else
          UserProfile
            .where(user_id: user_ids)
            .pluck(:user_id, *profile_columns)
            .to_h { |user_id, *values| [user_id, profile_columns.zip(values).to_h] }
        end
      columns = sources.filter_map { |source| STAT_COLUMNS[source] }.uniq
      @stats =
        if columns.empty?
          {}
        else
          UserStat
            .where(user_id: user_ids)
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
      custom_keys = @field_types.keys + sources.filter_map { |s| self.class.custom_field_name(s) }
      @custom_values = User.custom_fields_for_ids(user_ids, custom_keys)
    end

    def self.name_parts(user)
      name = user.name.presence || user.username
      name.include?(" ") ? name.split(" ", 2) : [nil, name]
    end

    def value(source, user)
      case source
      when "first"
        return self.class.name_parts(user).first.presence
      when "last"
        return self.class.name_parts(user).last
      when "profile"
        return user.full_url
      when "trust"
        return user.trust_level
      when "seen"
        return user.last_seen_at
      when "first_seen"
        return user.first_seen_at
      when "posts_read30"
        return @recent_reads.fetch(user.id, 0)
      when "likes_given30"
        return @recent_likes.fetch(user.id, 0)
      when "posts30"
        return @recent_posts.fetch(user.id, 0)
      when "groups"
        return Array(@groups[user.id]).map(&:last)
      end
      if column = PROFILE_COLUMNS[source]
        return @profiles.dig(user.id, column).presence
      end
      if column = STAT_COLUMNS[source]
        return @stats.dig(user.id, column) || 0
      end

      if name = self.class.custom_field_name(source)
        value = @custom_values.dig(user.id, name)
        return nil if value.nil? || value == ""
        return value.map { |item| item.is_a?(String) ? item : item.to_json } if value.is_a?(Array)
        return value.is_a?(String) ? value : value.to_json
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

    def fingerprint_value(source, user)
      return @custom_values.dig(user.id, source) if @field_types[source] == "date"
      value(source, user)
    end
  end
end
