# frozen_string_literal: true

require "time"

module Salesforce
  class FieldMapping
    def initialize(mappings, fields, &source_value)
      @mappings = mappings
      @fields = fields.index_by { |field| field.fetch("name") }
      @source_value = source_value
    end

    def values(record)
      @mappings.each_with_object({}) do |mapping, result|
        destination = mapping.fetch("destination")
        field = @fields.fetch(destination)
        next unless field[record ? "updateable" : "createable"]
        existing = record && record[destination]
        next if kept?(mapping, record)
        incoming = value(mapping)
        next if incoming.nil? || incoming == "" || same_value?(existing, incoming, field)
        result[destination] = incoming
      end
    end

    def kept?(mapping, record)
      existing = record && record[mapping.fetch("destination")]
      record && mapping["policy"] == "keep" && !existing.nil? && existing != ""
    end

    def same_value?(existing, incoming, field)
      return true if existing == incoming
      return false unless field["type"] == "datetime"

      Time.iso8601(existing) == Time.iso8601(incoming)
    rescue ArgumentError, TypeError
      false
    end

    def value(mapping)
      field = @fields.fetch(mapping.fetch("destination"))
      value =
        (
          if mapping["source"] == "static"
            mapping["value"]
          else
            @source_value.call(UserSyncSources.key(mapping), field)
          end
        )
      return value if value.nil? || value == ""
      return value.to_date.iso8601 if field["type"] == "date"
      if field["type"] == "datetime"
        return value.is_a?(Date) ? value.to_date.to_time(:utc).iso8601 : value.utc.iso8601
      end
      return value.join(field["type"] == "multipicklist" ? ";" : ", ") if value.is_a?(Array)
      value
    end
  end
end
