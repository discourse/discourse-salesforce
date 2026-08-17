# frozen_string_literal: true

module ::Salesforce
  module Associations
    BATCH_SIZE = 100
    ID_PATTERN = /\A[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?\z/
    ID_PREFIXES = { "Case" => "500", "Contact" => "003", "Lead" => "00Q" }.freeze

    def self.prune_dead!(api: Api.new)
      counts = { users: 0, posts: 0, cases: 0, settings: 0 }

      counts[:users] += prune_user_links(api, Contact)
      counts[:users] += prune_user_links(api, Lead)
      counts[:settings] = prune_default_contact(api)
      case_counts = prune_cases(api)
      counts.merge!(case_counts) { |_, total, count| total + count }

      counts
    end

    def self.prune_user_links(api, person_class)
      count = 0

      UserCustomField
        .where(name: person_class::ID_FIELD)
        .in_batches(of: BATCH_SIZE) do |batch|
          rows = batch.pluck(:id, :user_id, :value)
          dead_values = dead_ids(api, person_class::OBJECT_NAME, rows.map(&:last))
          row_ids = rows.filter_map { |id, _, value| id if dead_values.include?(value) }
          next if row_ids.empty?

          user_ids = []
          UserCustomField.transaction do
            fields =
              UserCustomField.lock.where(
                id: row_ids,
                name: person_class::ID_FIELD,
                value: dead_values,
              )
            user_ids = fields.pluck(:user_id)
            count += fields.delete_all
          end

          next if user_ids.empty? || person_class.group.blank?

          linked_user_ids =
            UserCustomField
              .where(user_id: user_ids, name: person_class::ID_FIELD)
              .distinct
              .pluck(:user_id)
          person_class.group.bulk_remove(user_ids - linked_user_ids)
        end

      count
    end

    def self.prune_default_contact(api)
      contact_id = SiteSetting.salesforce_default_contact_id_for_case_sync
      return 0 if contact_id.blank? || !dead_ids(api, "Contact", [contact_id]).include?(contact_id)

      return 0 if SiteSetting.salesforce_default_contact_id_for_case_sync != contact_id

      SiteSetting.salesforce_default_contact_id_for_case_sync = ""
      1
    end

    def self.prune_cases(api)
      counts = { posts: 0, cases: 0 }

      Case.in_batches(of: BATCH_SIZE) do |batch|
        rows = batch.pluck(:id, :uid, :topic_id)
        dead_uids = dead_ids(api, "Case", rows.map { |_, uid, _| uid })
        candidates = rows.select { |_, uid, _| dead_uids.include?(uid) }
        next if candidates.empty?

        candidate_uids = candidates.to_h { |id, uid, _| [id, uid] }

        ActiveRecord::Base.transaction do
          current_rows = Case.lock.where(id: candidate_uids.keys).pluck(:id, :uid, :topic_id)
          current_rows.select! { |id, uid, _| candidate_uids[id] == uid }
          next if current_rows.empty?

          case_ids = current_rows.map(&:first)
          topic_ids = current_rows.map(&:last).uniq
          counts[:cases] += Case.where(id: case_ids).delete_all

          remaining_topic_ids = Case.where(topic_id: topic_ids).distinct.pluck(:topic_id)
          orphaned_topic_ids = topic_ids - remaining_topic_ids
          next if orphaned_topic_ids.empty?

          TopicCustomField.where(
            name: ::CaseMixin::HAS_SALESFORCE_CASE,
            topic_id: orphaned_topic_ids,
          ).delete_all
          counts[:posts] += PostCustomField.where(
            name: CaseComment::ID_FIELD,
            post_id: Post.where(topic_id: orphaned_topic_ids).select(:id),
          ).delete_all
        end
      end

      counts
    end

    def self.dead_ids(api, object_name, ids)
      ids = ids.uniq
      prefix = ID_PREFIXES.fetch(object_name)
      valid_ids = ids.select { |id| ID_PATTERN.match?(id.to_s) && id.start_with?(prefix) }
      dead_ids = ids - valid_ids

      valid_ids.each_slice(BATCH_SIZE) do |slice|
        records = api.get("composite/sobjects/#{object_name}?fields=Id&ids=#{slice.join(",")}")
        if !records.is_a?(Array) || records.length != slice.length
          raise InvalidApiResponse, "Unexpected Salesforce #{object_name} lookup response"
        end

        slice
          .zip(records)
          .each do |id, record|
            if record.nil?
              dead_ids << id
            elsif !matching_id?(record["Id"], id)
              raise InvalidApiResponse, "Unexpected Salesforce #{object_name} lookup record"
            end
          end
      end

      dead_ids
    end

    def self.matching_id?(returned_id, requested_id)
      ID_PATTERN.match?(returned_id.to_s) && returned_id.first(15) == requested_id.first(15)
    end
    private_class_method :matching_id?
  end
end
