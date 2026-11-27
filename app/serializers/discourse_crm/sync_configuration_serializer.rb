# frozen_string_literal: true

module DiscourseCrm
  class SyncConfigurationSerializer < ApplicationSerializer
    attributes :id,
               :name,
               :kind,
               :provider,
               :direction,
               :schedule,
               :backfill,
               :group_ids,
               :groups,
               :mappings,
               :connection_changed,
               :active,
               :sync_status,
               :segment_count
    # AMS reserves `object` for the serialized record, so the CRM object name needs a key alias.
    attribute :crm_object, key: :object

    def crm_object
      object.object
    end

    def group_ids
      sorted_groups.map(&:id)
    end

    def groups
      sorted_groups.map(&:name)
    end

    def connection_changed
      object.connection_changed?
    end

    def segment_count
      object.segments.count
    end

    def include_segment_count?
      object.inbound?
    end

    private

    def sorted_groups
      @sorted_groups ||= object.groups.sort_by(&:name)
    end
  end
end
