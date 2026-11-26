# frozen_string_literal: true

module DiscourseCrm
  # Checks a pull's mappings against the fields its CRM object offers. Each field carries the
  # generic `source_type` that decides which Discourse fields it can fill.
  module PullMappings
    def self.validate!(configuration, fields, copies_to_discourse: true)
      mappings = configuration.mappings
      source_types = fields.to_h { |field| [field[:name], field[:source_type]] }
      sources = mappings.map { |mapping| mapping["source"] }
      valid =
        mappings.all? do |mapping|
          mapping["object"] == configuration.object && source_types.key?(mapping["source"]) &&
            (copies_to_discourse || mapping["destination"].blank?)
        end
      raise Discourse::InvalidParameters.new(:mappings) if !valid || sources.uniq != sources
      return unless copies_to_discourse
      UserSyncDestinations.validate!(configuration.destination_mappings, source_types)
    end
  end
end
