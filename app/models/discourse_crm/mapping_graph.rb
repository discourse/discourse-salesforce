# frozen_string_literal: true

module DiscourseCrm
  # Push mappings copy Discourse fields to CRM fields and pull mappings copy CRM fields
  # to Discourse fields. A cycle of overwriting mappings would keep copying a value back
  # to where it came from, and two pulls overwriting one Discourse field would replace each
  # other's value on every run. A "keep" mapping only fills empty values, so a cycle or a
  # shared field that involves one settles after a single round and is allowed.
  class MappingGraph
    PROVIDER_NAMES = { "salesforce" => "Salesforce", "hubspot" => "HubSpot" }.freeze
    # Pushes can send the name's first or remaining words; both come from the Discourse name.
    NAME_SOURCES = %w[first last].freeze

    def self.validate!(configuration)
      # Configurations of a disabled provider come back when it is enabled again, so they
      # count too. Ones saved for another CRM account cannot run until they are saved again.
      others =
        SyncConfiguration
          .where(active: true)
          .where.not(id: configuration.id)
          .reject(&:connection_changed?)
      new([*others, configuration]).validate!(configuration)
    end

    def initialize(configurations)
      @configurations = configurations
    end

    def validate!(configuration)
      validate_unique_destinations!(configuration)
      cycle = find_cycle(configuration)
      return unless cycle
      raise InvalidMapping.new(
              I18n.t(
                "discourse_crm.mapping_errors.loop",
                path: cycle.map { |node| label(node) }.join(" → "),
              ),
              mapping: mapping_in(cycle, configuration),
            )
    end

    private

    # Pulls that keep existing values only fill blanks, so they can share a Discourse field.
    def validate_unique_destinations!(configuration)
      pulls(configuration).each do |mapping|
        next unless overwrites?(mapping)
        other =
          @configurations.find do |candidate|
            !candidate.equal?(configuration) &&
              pulls(candidate).any? do |item|
                item["destination"] == mapping["destination"] && overwrites?(item)
              end
          end
        next unless other
        raise InvalidMapping.new(
                I18n.t(
                  "discourse_crm.mapping_errors.duplicate_destination",
                  field: UserSyncDestinations.label(mapping["destination"]),
                  configuration: other.name,
                ),
                mapping: mapping,
              )
      end
    end

    # Other configurations were checked when they were saved, so a new loop must pass through
    # the saved configuration. Starting there also reports the loop from the admin's change.
    def find_cycle(configuration)
      visited = Set.new
      configuration_edges(configuration)
        .map(&:first)
        .uniq
        .each do |start|
          cycle = walk(start, [], visited)
          return cycle if cycle
        end
      nil
    end

    def mapping_in(cycle, configuration)
      saved_edges = configuration_edges(configuration)
      cycle.each_cons(2) do |from, to|
        edge = saved_edges.find { |source, target, _| source == from && target == to }
        return edge.last if edge
      end
      nil
    end

    def walk(node, path, visited)
      if (index = path.index(node))
        return *path[index..], node
      end
      return if visited.include?(node)
      visited << node
      edges
        .fetch(node, [])
        .each do |target|
          cycle = walk(target, [*path, node], visited)
          return cycle if cycle
        end
      nil
    end

    def edges
      @edges ||=
        @configurations
          .flat_map { |configuration| configuration_edges(configuration) }
          .group_by(&:first)
          .transform_values { |configuration_edges| configuration_edges.map(&:second).uniq }
    end

    def configuration_edges(configuration)
      if configuration.inbound?
        pulls(configuration).flat_map do |mapping|
          next [] unless overwrites?(mapping)
          object = mapping["object"] || configuration.object
          source_fields(configuration, mapping["source"]).map do |field|
            [
              crm_node(configuration, object, field),
              discourse_node(mapping["destination"]),
              mapping,
            ]
          end
        end
      else
        configuration.mappings.filter_map do |mapping|
          next if mapping["source"] == "static" || !overwrites?(mapping)
          [
            discourse_node(mapping["source"]),
            crm_node(configuration, configuration.object, mapping["destination"]),
            mapping,
          ]
        end
      end
    end

    # A pull source can combine several CRM fields, such as HubSpot's first and last name.
    def source_fields(configuration, source)
      flow = configuration.flow
      flow.respond_to?(:source_fields) ? flow.source_fields(source) : [source]
    end

    def overwrites?(mapping)
      mapping["policy"] != "keep"
    end

    def pulls(configuration)
      configuration.inbound? ? configuration.destination_mappings : []
    end

    def discourse_node(field)
      [:discourse, NAME_SOURCES.include?(field) ? "name" : field]
    end

    def crm_node(configuration, object, field)
      [:crm, configuration.provider, configuration.account, object, field.to_s]
    end

    def label(node)
      if node.first == :discourse
        "Discourse #{UserSyncDestinations.label(node.last)}"
      else
        _, provider, _, object, field = node
        "#{PROVIDER_NAMES.fetch(provider, provider)} #{object}.#{field}"
      end
    end
  end
end
