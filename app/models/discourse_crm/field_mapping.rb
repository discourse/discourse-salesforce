# frozen_string_literal: true

require "time"
require "bigdecimal"

module DiscourseCrm
  class FieldMapping
    def self.field_type(type)
      return "number" if %w[int double currency percent].include?(type)
      return "date" if %w[date datetime].include?(type)
      if %w[
           string
           textarea
           email
           phone
           url
           picklist
           multipicklist
           combobox
           encryptedstring
         ].include?(type)
        return "text"
      end
      type
    end

    private_class_method :field_type

    def self.validate!(mappings, fields, email_field:, required_fields:)
      unless mappings.is_a?(Array) && mappings.all? { |mapping| mapping.is_a?(Hash) }
        raise Discourse::InvalidParameters.new(:mappings)
      end
      source_types =
        UserSyncSources::SOURCE_TYPES.merge(
          UserSyncSources.custom_sources.to_h { |source| [source[:id], source[:type]] },
        )
      destinations = mappings.map { |mapping| mapping["destination"] }
      valid = destinations.uniq.size == destinations.size && !destinations.include?(email_field)
      valid &&= (required_fields - destinations).empty?
      valid &&= fields.any? { |field| field["name"] == email_field && field["createable"] }
      valid &&=
        mappings.all? do |mapping|
          field = fields.find { |item| item["name"] == mapping["destination"] }
          static_value_valid =
            mapping["source"] != "static" ||
              (
                mapping["value"].is_a?(String) && mapping["value"].present? &&
                  mapping["value"].length <= 1000
              )
          static_value_valid && field && source_types[mapping["source"]].present? &&
            source_types[mapping["source"]] == field_type(field["type"]) &&
            %w[keep overwrite].include?(mapping["policy"])
        end
      raise Discourse::InvalidParameters.new(:mappings) unless valid
    end

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
      return false if existing.nil? || existing == ""
      case field["type"]
      when "int", "double", "currency", "percent"
        BigDecimal(existing.to_s) == BigDecimal(incoming.to_s)
      when "boolean"
        %w[true false].include?(existing.to_s) && existing.to_s == incoming.to_s
      when "datetime"
        Time.iso8601(existing) == Time.iso8601(incoming)
      else
        false
      end
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
            @source_value.call(mapping["source"], field)
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
