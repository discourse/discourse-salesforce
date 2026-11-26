# frozen_string_literal: true

module DiscourseCrm
  # Discourse user fields that inbound syncs can fill from CRM values.
  class UserSyncDestinations
    BUILT_IN = { "name" => "text", "bio" => "text", "website" => "text" }.freeze
    PROFILE_COLUMNS = UserSyncSources::PROFILE_COLUMNS
    POLICIES = %w[keep overwrite].freeze
    USER_FIELD_TYPES = { "confirm" => "boolean", "date" => "date", "number" => "number" }.freeze
    CUSTOM_FIELD_TYPES = { string: "text", integer: "number", boolean: "boolean" }.freeze
    ACCEPTED_SOURCE_TYPES = {
      "text" => %w[text number],
      "number" => %w[number],
      "date" => %w[date],
      "boolean" => %w[boolean],
    }.freeze

    Result = Data.define(:changed, :rejected)
    Applied = Data.define(:changed_user_ids, :errors)

    # Fields the login provider replaces on every login are left out. `accepts` lists the
    # generic CRM field types each destination can hold.
    def self.all
      built_in =
        BUILT_IN
          .reject { |id, _| overridden_on_login?(id) }
          .map { |id, type| destination(id, built_in_label(id), type, "details") }
      user_fields =
        UserField
          .order(:position, :id)
          .map do |field|
            destination(
              "#{User::USER_FIELD_PREFIX}#{field.id}",
              user_field_label(field),
              USER_FIELD_TYPES.fetch(field.field_type, "text"),
              "custom",
            )
          end
      custom_fields =
        UserSyncSources.custom_field_names.filter_map do |name|
          type = custom_field_type(name)
          next unless type
          destination("#{UserSyncSources::CUSTOM_FIELD_PREFIX}#{name}", name, type, "custom")
        end
      built_in + user_fields + custom_fields
    end

    # Plugins can register a type for a custom field, and Discourse converts stored values
    # to it. Fields holding lists or JSON have no single CRM value to copy.
    def self.custom_field_type(name)
      descriptor = User.get_custom_field_descriptor(name)
      return if descriptor.array_type?
      CUSTOM_FIELD_TYPES[descriptor.type]
    end

    def self.destination(id, name, type, group)
      { id:, name:, type:, group:, accepts: ACCEPTED_SOURCE_TYPES.fetch(type) }
    end
    private_class_method :destination

    def self.label(field)
      return built_in_label(field) if BUILT_IN.key?(field)
      user_field_id = field[/\A#{User::USER_FIELD_PREFIX}(\d+)\z/, 1]
      user_field = user_field_id && UserField.find_by(id: user_field_id)
      return user_field_label(user_field) if user_field
      UserSyncSources.custom_field_name(field) || field
    end

    def self.user_field_label(field)
      field.name.presence || field.description
    end
    private_class_method :user_field_label

    def self.built_in_label(field)
      I18n.t("discourse_crm.destinations.#{field}")
    end
    private_class_method :built_in_label

    def self.validate!(mappings, source_types)
      overridden = mappings.find { |mapping| overridden_on_login?(mapping["destination"]) }
      if overridden
        raise InvalidMapping.new(
                I18n.t(
                  "discourse_crm.mapping_errors.overridden_on_login",
                  field: label(overridden["destination"]),
                ),
                mapping: overridden,
              )
      end

      types = all.to_h { |destination| [destination[:id], destination[:type]] }
      destinations = mappings.map { |mapping| mapping["destination"] }
      valid =
        destinations.uniq.size == destinations.size &&
          mappings.all? do |mapping|
            type = types[mapping["destination"]]
            type && POLICIES.include?(mapping["policy"]) &&
              ACCEPTED_SOURCE_TYPES.fetch(type).include?(source_types[mapping["source"]])
          end
      raise Discourse::InvalidParameters.new(:mappings) unless valid
    end

    def self.overridden_on_login?(destination)
      case destination
      when "name"
        SiteSetting.auth_overrides_name
      when "bio"
        SiteSetting.enable_discourse_connect && SiteSetting.discourse_connect_overrides_bio
      when "website"
        SiteSetting.enable_discourse_connect && SiteSetting.discourse_connect_overrides_website
      else
        false
      end
    end
    private_class_method :overridden_on_login?

    # Fills each user's mapped fields from the CRM record the importer chose for them.
    def self.apply(mappings, properties_by_user_id)
      changed = Set.new
      errors = {}
      # Login settings can change after a pull is saved; the login provider then owns the field.
      mappings = mappings.reject { |mapping| overridden_on_login?(mapping["destination"]) }
      return Applied.new(changed, errors) if mappings.empty? || properties_by_user_id.empty?
      destinations = new
      User
        .where(id: properties_by_user_id.keys)
        .includes(:user_profile)
        .find_each do |user|
          result = destinations.write(user, mappings, properties_by_user_id.fetch(user.id))
          changed << user.id if result.changed
          errors[user.id] = InvalidDestinationValue.new(result.rejected) if result.rejected.any?
        end
      Applied.new(changed, errors)
    end

    def initialize
      @user_fields =
        UserField
          .includes(:user_field_options)
          .index_by { |field| "#{User::USER_FIELD_PREFIX}#{field.id}" }
      @watched_field_ids =
        if SiteSetting.disable_watched_word_checking_in_user_fields
          Set.new
        else
          UserField.public_fields.user_editable_text_fields.pluck(:id).to_set
        end
    end

    # Copies CRM values into the user's mapped fields. Empty CRM values never clear a field.
    def write(user, mappings, properties)
      values = {}
      rejected = []
      keep = Set.new
      mappings.each do |mapping|
        destination = mapping.fetch("destination")
        # The user field was deleted after the pull was saved.
        next if user_field?(destination) && !@user_fields.key?(destination)
        incoming = properties[mapping.fetch("source")]
        next if incoming.nil? || incoming == ""
        existing = read(user, destination)
        # A boolean custom field reads back false, which is a value, not a blank.
        next if mapping["policy"] == "keep" && (existing.present? || existing == false)
        value = convert(destination, text(incoming))
        if value.nil?
          rejected << destination
        elsif !same?(value, existing)
          values[destination] = value
          keep << destination if mapping["policy"] == "keep"
        end
      end
      changed = [
        save_name(user, values["name"], rejected),
        save_profile(user, values.slice(*PROFILE_COLUMNS.keys), rejected),
        save_custom_fields(user, values.except(*BUILT_IN.keys), rejected, keep),
      ].any?
      Result.new(changed, rejected)
    end

    private

    def read(user, destination)
      if destination == "name"
        user.name
      elsif column = PROFILE_COLUMNS[destination]
        user.user_profile&.public_send(column)
      else
        value = user.custom_fields[custom_field_key(destination)]
        # A multi-select with one option is stored as one row and read back as a string.
        if value && @user_fields[destination]&.field_type == "multiselect"
          Array(value)
        else
          value
        end
      end
    end

    def convert(destination, value)
      return website(value) if destination == "website"
      return value if BUILT_IN.key?(destination)
      field = @user_fields[destination]
      return convert_custom_field(destination, value) unless field
      case field.field_type
      when "number"
        value if UserField.cast_number(value)
      when "date"
        # HubSpot sends date-only values and ISO datetimes; user fields keep the date.
        Date.iso8601(value.first(10)).iso8601
      when "confirm"
        value.downcase if %w[true false].include?(value.downcase)
      when "dropdown"
        value if option?(field, value)
      when "multiselect"
        values = value.split(";").compact_blank.uniq
        values if values.any? && values.all? { |item| option?(field, item) }
      when "text", "textarea"
        watched_text(field, value) if value.length <= UserField.max_length
      else
        value
      end
    rescue Date::Error
      nil
    end

    # Salesforce sends numbers as JSON floats, so 250 arrives as 250.0 and 10000000 as 1.0E7.
    def text(value)
      return value.to_s unless value.is_a?(Float)
      value == value.truncate ? value.to_i.to_s : BigDecimal(value.to_s).to_s("F")
    end

    # Discourse accepts only http(s) websites; like its profile form, add http:// when the
    # CRM value has no scheme.
    def website(value)
      # "acme.io:8443" parses with "acme.io" as its scheme, so check for http(s) itself.
      %w[http https].include?(URI.parse(value).scheme&.downcase) ? value : "http://#{value}"
    rescue URI::Error
      value
    end

    # Values match what Discourse reads back for the field's registered type.
    def convert_custom_field(destination, value)
      case self.class.custom_field_type(custom_field_key(destination))
      when "text"
        value
      when "number"
        # Base 10, so a zero-padded "010" stays ten.
        Integer(value, 10, exception: false)
      when "boolean"
        { "true" => true, "false" => false }[value.downcase]
      end
    end

    # Public text fields follow the watched-word rules a user meets when editing the profile.
    def watched_text(field, value)
      return value if @watched_field_ids.exclude?(field.id)
      return if WordWatcher.new(value).should_block?.present?
      WordWatcher.replace_text(WordWatcher.censor_text(value))
    end

    def user_field?(destination)
      destination.start_with?(User::USER_FIELD_PREFIX)
    end

    # Multi-select options carry no order, so the same options in another order are unchanged.
    def same?(value, existing)
      if value.is_a?(Array) && existing.is_a?(Array)
        value.sort == existing.sort
      else
        value == existing
      end
    end

    def option?(field, value)
      field.user_field_options.any? { |option| option.value == value }
    end

    def save_name(user, name, rejected)
      return false if name.nil?
      user.name = name
      # Only the name's own checks decide; an older account failing newer rules for other
      # attributes still takes the pulled name. Callbacks such as search indexing still run.
      user.valid?
      if user.errors[:name].any?
        user.restore_attributes([:name])
        user.errors.clear
        rejected << "name"
        return false
      end
      user.save!(validate: false)
      true
    end

    # Bio and website save one at a time, so one rejected value does not block the other.
    def save_profile(user, values, rejected)
      return false if values.empty?
      profile = user.user_profile || user.build_user_profile
      saved =
        values.map do |destination, value|
          column = PROFILE_COLUMNS.fetch(destination)
          profile[column] = value
          rollback = -> do
            profile.restore_attributes([column])
            profile.errors.clear
          end
          save(rejected, [destination], rollback:) { profile.save! }
        end
      saved.any?
    end

    # Writes only the mapped keys. Discourse's save_custom_fields rewrites every key, which
    # would drop custom fields stored by others after this user's fields were read.
    def save_custom_fields(user, values, rejected, keep)
      return false if values.empty?
      written =
        values.filter_map do |destination, value|
          result =
            write_custom_field(
              user,
              custom_field_key(destination),
              value,
              keep: keep.include?(destination),
            )
          rejected << destination if result == :rejected
          destination if result == :written
        end
      user.clear_custom_fields
      # User search reads searchable fields when the user is indexed, which saving a user
      # does but writing their custom fields does not.
      if written.any? { |destination| @user_fields[destination]&.searchable }
        user.user_custom_fields.reset
        SearchIndexer.index(user, force: true)
      end
      written.any?
    end

    # Returns :written, :rejected, or :kept when a keep mapping finds the field filled since
    # it was read.
    def write_custom_field(user, key, value, keep:)
      descriptor = User.get_custom_field_descriptor(key)
      stored = Array(value).map { |item| descriptor.serialize(item) }
      return :rejected if stored.any? { |item| item.bytesize > descriptor.max_length }
      stored_keys =
        UserCustomField.where(user_id: user.id).where.not(name: key).distinct.count(:name)
      return :rejected if stored_keys >= HasCustomFields::CUSTOM_FIELDS_MAX_ITEMS

      now = Time.zone.now
      UserCustomField.transaction do
        rows = UserCustomField.where(user_id: user.id, name: key)
        # Checked again next to the write, so a value stored since the read is kept.
        next :kept if keep && rows.where.not(value: "").exists?
        rows.delete_all
        UserCustomField.insert_all!(
          stored.map do |item|
            { user_id: user.id, name: key, value: item, created_at: now, updated_at: now }
          end,
        )
        :written
      end
    end

    # Each part saves on its own so a value Discourse rejects does not block the others.
    def save(rejected, destinations, rollback:)
      ActiveRecord::Base.transaction(requires_new: true) { yield }
      true
    rescue ActiveRecord::RecordInvalid
      rollback.call
      rejected.concat(destinations)
      false
    end

    def custom_field_key(destination)
      UserSyncSources.custom_field_name(destination) || destination
    end
  end
end
