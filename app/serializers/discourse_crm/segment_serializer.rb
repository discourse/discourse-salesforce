# frozen_string_literal: true

module DiscourseCrm
  class SegmentSerializer < ApplicationSerializer
    attributes :id,
               :name,
               :provider,
               :conditions,
               :group_id,
               :group_name,
               :remove_unmatched,
               :member_count,
               :last_evaluated_at,
               :connection_changed,
               :missing_properties

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
      pulled = @options[:pulled_properties]&.dig([object.provider, object.account])
      pulled ||= Segment.pulled_properties(provider: object.provider, account: object.account)
      object.missing_properties(pulled)
    end
  end
end
