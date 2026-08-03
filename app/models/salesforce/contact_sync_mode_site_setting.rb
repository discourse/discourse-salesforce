# frozen_string_literal: true

require_dependency "enum_site_setting"

class Salesforce::ContactSyncModeSiteSetting < EnumSiteSetting
  def self.valid_value?(value)
    values.any? { |entry| entry[:value].to_s == value.to_s }
  end

  def self.values
    @values ||=
      %w[link_only fill_blank overwrite].map do |value|
        { name: "salesforce.contact_sync_mode.#{value}", value: value }
      end
  end

  def self.translate_names?
    true
  end
end
