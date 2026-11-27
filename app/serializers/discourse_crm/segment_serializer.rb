# frozen_string_literal: true

module DiscourseCrm
  class SegmentSerializer < ApplicationSerializer
    attributes :id,
               :name,
               :configuration_id,
               :configuration_name,
               :conditions,
               :group_id,
               :group_name,
               :remove_unmatched,
               :flair_enabled,
               :flair_text_property,
               :flair_properties,
               :flair_group_ids,
               :member_count,
               :last_evaluated_at,
               :connection_changed,
               :missing_properties

    def configuration_name
      object.configuration.name
    end

    def group_name
      object.group&.name
    end

    def member_count
      counts = @options[:member_counts]
      counts ? counts.fetch(object.id, 0) : object.members.count
    end

    def connection_changed
      object.connection_changed?
    end

    def missing_properties
      pulled = object.configuration.pulled_properties
      object.missing_properties(pulled) | object.missing_flair_properties(pulled)
    end
  end
end
