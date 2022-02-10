# frozen_string_literal: true

leads_group = Group.where(name: 'salesforce-leads').first_or_initialize(
  visibility_level: Group.visibility_levels[:staff],
  primary_group: true,
  title: 'Lead',
  flair_icon: 'fab-salesforce',
  bio_raw: 'Members are automatically synced from Salesforce via API',
  full_name: 'Salesforce Leads'
)
leads_group.save! if leads_group.new_record?

contacts_group = Group.where(name: 'salesforce-contacts').first_or_initialize(
  visibility_level: Group.visibility_levels[:staff],
  primary_group: true,
  title: 'Contact',
  flair_icon: 'fab-salesforce',
  bio_raw: 'Members are automatically synced from Salesforce via API',
  full_name: 'Salesforce Contacts'
)
contacts_group.save! if contacts_group.new_record?
