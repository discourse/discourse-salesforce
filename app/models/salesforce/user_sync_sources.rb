# frozen_string_literal: true

module Salesforce
  class UserSyncSources
    SOURCE_TYPES = {
      "first" => "text",
      "last" => "text",
      "profile" => "text",
      "bio" => "text",
      "website" => "text",
      "company" => "text",
      "posts" => "number",
      "posts30" => "number",
      "read_time" => "number",
      "posts_read" => "number",
      "topics_entered" => "number",
      "likes_given" => "number",
      "likes_received" => "number",
      "days_visited" => "number",
      "trust" => "number",
      "groups" => "text",
      "seen" => "date",
      "source" => "text",
      "static" => "text",
    }.freeze

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
      user_ids = users.map(&:id)
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
      @company_field = UserField.where("lower(name) = ?", "company").first if sources.include?(
        "company",
      )
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
      custom_keys = @field_types.keys
      custom_keys |= ["user_field_#{@company_field.id}"] if @company_field
      @custom_values = User.custom_fields_for_ids(user_ids, custom_keys)
    end

    def self.name_parts(user)
      name = user.name || user.username
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
      when "posts30"
        return @recent_posts.fetch(user.id, 0)
      when "groups"
        return Array(@groups[user.id]).map(&:last)
      when "company"
        return @custom_values.dig(user.id, "user_field_#{@company_field.id}") if @company_field
        return nil
      end
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
