# frozen_string_literal: true

Fabricator(:salesforce_case, class_name: ::Salesforce::Case) do
  topic
  uid { sequence(:uid) { |i| "case#{i}" } }
  contact_id { sequence(:contact_id) { |i| "contact#{i}" } }
  subject "This is case title"
  description "This is the description of the Salesforce case."
  number "345678"
  status "New"
  last_synced_at 1.minute.ago
end

Fabricator(:verified_user, from: :user) { after_create { |user| user.activate } }

Fabricator(:sync_configuration, class_name: ::DiscourseCrm::SyncConfiguration) do
  transient :groups

  provider "salesforce"
  account { SiteSetting.salesforce_instance_url }
  name "Lead sync"
  kind "users"
  object "Lead"
  schedule "daily"
  backfill true
  active true
  mappings do
    [
      { "source" => "last", "destination" => "LastName", "policy" => "keep" },
      {
        "source" => "static",
        "value" => "Unknown",
        "destination" => "Company",
        "policy" => "keep",
      },
    ]
  end

  after_create do |configuration, transients|
    Array(transients[:groups]).each do |group|
      configuration.configuration_groups.create!(group_id: group.id)
    end
  end
end
