# frozen_string_literal: true

if Salesforce.leads_group.blank?
  group = Group.create!(
    name: 'salesforce-leads',
    visibility_level: Group.visibility_levels[:staff],
    primary_group: true,
    title: 'Lead',
    flair_icon: 'fab-salesforce',
    bio_raw: 'Members are automatically synced from Salesforce via API',
    full_name: 'Salesforce Leads'
  )
  SiteSetting.salesforce_leads_group_id = group.id
end

if Salesforce.contacts_group.blank?
  group = Group.create!(
    name: 'salesforce-contacts',
    visibility_level: Group.visibility_levels[:staff],
    primary_group: true,
    title: 'Contact',
    flair_icon: 'fab-salesforce',
    bio_raw: 'Members are automatically synced from Salesforce via API',
    full_name: 'Salesforce Contacts'
  )
  SiteSetting.salesforce_contacts_group_id = group.id
end
