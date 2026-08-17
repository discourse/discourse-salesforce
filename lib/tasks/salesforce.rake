# frozen_string_literal: true

# Run after connecting to a different organization or refreshing a sandbox.
desc "Remove stored links the connected Salesforce user cannot resolve"
task "salesforce:prune_dead_associations" => :environment do
  counts = Salesforce::Associations.prune_dead!(api: Salesforce::Api.new)

  puts "Pruned #{counts[:users]} user links, #{counts[:posts]} post references, #{counts[:cases]} case links, and #{counts[:settings]} settings."
end
