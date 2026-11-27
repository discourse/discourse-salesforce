# frozen_string_literal: true

module DiscourseCrm
  class Flair
    def self.visible_segments(guardian)
      return [] unless SiteSetting.crm_segments_enabled
      Segment
        .with_flair
        .joins(:configuration)
        .merge(SyncConfiguration.active.inbound)
        .includes(:configuration)
        .order(:id)
        .select { |segment| segment.flair_visible_to?(guardian.user) }
    end

    def self.for_users(user_ids, guardian:)
      return {} if user_ids.empty?
      segments = guardian.crm_flair_segments
      return {} if segments.empty?

      segment_by_user = {}
      SegmentMember
        .where(segment_id: segments.map(&:id), user_id: user_ids)
        .order(:segment_id)
        .pluck(:user_id, :segment_id)
        .each do |user_id, segment_id|
          segment_by_user[user_id] ||= segments.find { |segment| segment.id == segment_id }
        end
      return {} if segment_by_user.empty?

      records_by_user = {}
      segment_by_user
        .group_by { |_, segment| segment.configuration }
        .each do |configuration, pairs|
          RecordLink
            .where(
              provider: configuration.provider,
              account: configuration.account,
              direction: "inbound",
              user_id: pairs.map(&:first),
            )
            .includes(record: :company)
            .group_by(&:user_id)
            .each { |user_id, links| records_by_user[user_id] = links.filter_map(&:record) }
        end

      segment_by_user
        .filter_map do |user_id, segment|
          payload = build(segment, records_by_user.fetch(user_id, []))
          [user_id, payload] if payload
        end
        .to_h
    end

    def self.build(segment, records)
      record = records.find { |candidate| segment.matches?([candidate]) } || records.first
      return if record.nil?
      configuration = segment.configuration
      definition = configuration.provider_definition
      pulled =
        configuration.pulled_properties.map { |property| "#{property[:object]}.#{property[:name]}" }
      text_property = segment.flair_text_property if pulled.include?(segment.flair_text_property)
      {
        provider: configuration.provider,
        icon: definition.icon,
        text: property_value(configuration, record, text_property).presence || segment.name,
        properties:
          (segment.flair_properties & pulled).filter_map do |id|
            value = property_value(configuration, record, id)
            next if value.blank?
            object, name = id.split(".", 2)
            { label: configuration.property_label(object, name), value: value }
          end,
        url: definition.record_url(record),
      }
    end

    def self.property_value(configuration, record, id)
      return if id.blank?
      object, name = id.split(".", 2)
      source = object == record.object ? record : record.company
      return if source.nil? || source.object != object
      value = source.data[name]
      return if value.blank?
      configuration.value_label(object, name, value).to_s
    end

    private_class_method :property_value
  end
end
