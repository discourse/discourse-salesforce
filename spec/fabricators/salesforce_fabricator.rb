# frozen_string_literal: true

Fabricator(:salesforce_case, from: "::Salesforce::Case") do
  topic
  uid { sequence(:uid) }
  contact_id { sequence(:contact_id) }
  subject "This is case title"
  description "This is the description of the Salesforce case."
  number "345678"
  status "New"
  last_synced_at 1.minutes.ago
end
