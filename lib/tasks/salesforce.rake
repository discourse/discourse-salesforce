# frozen_string_literal: true

# Run after connecting to a different organization or refreshing a sandbox.
# DRY_RUN=1 prints the report without removing anything.
desc "Remove stored links the connected Salesforce user cannot resolve"
task "salesforce:prune_dead_associations" => :environment do
  api = Salesforce::Api.new
  found = 0

  { Salesforce::Contact => "contact", Salesforce::Lead => "lead" }.each do |person_class, label|
    fields = UserCustomField.where(name: person_class::ID_FIELD)
    dead = Salesforce::Associations.dead_ids(api, person_class::OBJECT_NAME, fields.pluck(:value))
    fields
      .where(value: dead)
      .includes(:user)
      .find_each do |field|
        found += 1
        puts "dead #{label} #{field.value}: #{Discourse.base_url}/u/#{field.user&.username} (user #{field.user_id})"
      end
  end

  dead_uids = Salesforce::Associations.dead_ids(api, "Case", Salesforce::Case.pluck(:uid))
  Salesforce::Case
    .where(uid: dead_uids)
    .includes(:topic)
    .find_each do |salesforce_case|
      found += 1
      puts "dead case #{salesforce_case.uid} (##{salesforce_case.number}): " \
             "#{Discourse.base_url}/t/#{salesforce_case.topic_id} #{salesforce_case.topic&.title.inspect}"
    end

  default_id = SiteSetting.salesforce_default_contact_id_for_case_sync
  if default_id.present? && Salesforce::Associations.dead_ids(api, "Contact", [default_id]).any?
    found += 1
    puts "dead default contact setting: #{default_id}"
  end

  puts "No dead links found." if found == 0

  if ENV["DRY_RUN"] == "1"
    puts "Dry run: nothing removed."
  else
    counts = Salesforce::Associations.prune_dead!(api: api)
    puts "Pruned #{counts[:users]} user links, #{counts[:posts]} post references, #{counts[:cases]} case links, and #{counts[:settings]} settings."
  end
end
