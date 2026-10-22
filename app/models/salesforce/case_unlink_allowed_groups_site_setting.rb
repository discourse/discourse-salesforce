# frozen_string_literal: true

require_dependency "enum_site_setting"

class Salesforce::CaseUnlinkAllowedGroupsSiteSetting < EnumSiteSetting
  def self.valid_value?(value)
    (value.to_s.split("|") - values.map { |entry| entry[:value] }).empty?
  end

  def self.values
    %w[admins moderators].map do |group|
      { name: "salesforce.case_unlink_allowed_groups.#{group}", value: group }
    end
  end

  def self.translate_names?
    true
  end
end
