# frozen_string_literal: true

module ::Salesforce
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace Salesforce
    config.autoload_paths << File.join(config.root, "lib")
  end

  def self.api
    @api ||= Api.new
  end

  def self.leads_group
    group_id = SiteSetting.salesforce_leads_group_id
    return if group_id.blank?

    Group.find_by(id: group_id)
  end

  def self.contacts_group
    group_id = SiteSetting.salesforce_contacts_group_id
    return if group_id.blank?

    Group.find_by(id: group_id)
  end

  def self.seed_groups!
    if leads_group.blank?
      group =
        Group.where(name: "salesforce-leads").first_or_create!(
          name: "salesforce-leads",
          visibility_level: Group.visibility_levels[:staff],
          primary_group: true,
          bio_raw: "Members are automatically synced from Salesforce via API",
          full_name: "Salesforce Leads",
        )
      SiteSetting.salesforce_leads_group_id = group.id
    end

    if contacts_group.blank?
      group =
        Group.where(name: "salesforce-contacts").first_or_create!(
          name: "salesforce-contacts",
          visibility_level: Group.visibility_levels[:staff],
          primary_group: true,
          bio_raw: "Members are automatically synced from Salesforce via API",
          full_name: "Salesforce Contacts",
        )
      SiteSetting.salesforce_contacts_group_id = group.id
    end
  end
end
