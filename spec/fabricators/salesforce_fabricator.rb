# frozen_string_literal: true

Fabricator(:salesforce_case, class_name: ::Salesforce::Case) do
  topic
  uid { sequence(:uid) { |i| "case#{i}" } }
  contact_id { sequence(:contact_id) { |i| "contact#{i}" } }
  subject "This is case title"
  description "This is the description of the Salesforce case."
  number "345678"
  status "New"
  last_synced_at 1.minutes.ago
end
