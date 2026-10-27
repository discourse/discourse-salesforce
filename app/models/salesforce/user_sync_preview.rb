# frozen_string_literal: true

module Salesforce
  class UserSyncPreview
    def self.users(group_name, query: nil)
      groups = GuidedSyncConfiguration.resolve_groups!(Array(group_name))
      users = Person.eligible_group_members(groups.select(:id))
      if query.present?
        pattern = "%#{User.sanitize_sql_like(query.to_s.first(100))}%"
        users = users.where("username ILIKE :query OR name ILIKE :query", query: pattern)
      end
      users.order(:username_lower, :id)
    end

    def self.sample_record(fields)
      samples = {
        "Email" => "member@example.com",
        "FirstName" => "Jordan",
        "LastName" => "Taylor",
        "LeadSource" => "Web",
        "Description" => nil,
      }
      fields.to_h do |field|
        value =
          if samples.key?(field["name"])
            samples[field["name"]]
          else
            case ConfiguredUserSync.field_type(field["type"])
            when "boolean"
              true
            when "number"
              42
            when "date"
              field["type"] == "datetime" ? "2026-01-01T12:00:00Z" : "2026-01-01"
            else
              I18n.t("salesforce.preview.sample_value")
            end
          end
        [field["name"], value]
      end
    end

    def self.sample_source(source, field, configuration)
      values = {
        "first" => "Alex",
        "last" => "Morgan",
        "profile" => "https://community.example.com/u/alex",
        "bio" => "I enjoy sharing ideas with the community.",
        "website" => "https://example.com",
        "company" => "Example company",
        "groups" => GuidedSyncConfiguration.group_names(configuration).join(", "),
        "trust" => 2,
      }
      return values[source] if values.key?(source)

      case ConfiguredUserSync.field_type(field["type"])
      when "boolean"
        true
      when "number"
        12
      when "date"
        Time.utc(2026, 1, 1, 12)
      else
        I18n.t("salesforce.preview.sample_value")
      end
    end

    def self.call(configuration, user_id: nil)
      configuration = configuration.deep_stringify_keys
      unless GuidedSyncConfiguration.group_names(configuration).present? &&
               %w[Lead Contact].include?(configuration["object"]) &&
               configuration["mappings"].is_a?(Array) && configuration["mappings"].size <= 50
        raise Discourse::InvalidParameters.new(:configuration)
      end
      members = users(GuidedSyncConfiguration.group_names(configuration))
      user = user_id.present? ? members.find(user_id) : members.first
      unless user
        return(
          {
            user: nil,
            sample: true,
            rows: ConfiguredUserSync.new(configuration, nil).preview(sample: true),
          }
        )
      end

      {
        user: {
          id: user.id,
          username: user.username,
          name: user.name,
        },
        rows: ConfiguredUserSync.new(configuration, user).preview,
      }
    end
  end
end
