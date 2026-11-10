# frozen_string_literal: true

module ::Salesforce
  module Associations
    BATCH_SIZE = 100
    ID_PATTERN = /\A[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?\z/
    ID_PREFIXES = { "Case" => "500", "Contact" => "003", "Lead" => "00Q" }.freeze

    def self.prune_dead!(api: Api.new)
      counts = { users: 0, posts: 0, cases: 0, settings: 0 }

      counts[:users] += prune_user_links(api, Contact)
      counts[:users] += prune_user_links(api, Lead) if Salesforce.leads_enabled?
      counts[:settings] = prune_default_contact(api)
      case_counts = prune_cases(api)
      counts.merge!(case_counts) { |_, total, count| total + count }

      counts
    end

    def self.prune_user_links(api, person_class)
      count = 0

      object = person_class::OBJECT_NAME
      account = SiteSetting.salesforce_instance_url
      configuration_ids =
        DiscourseCrm::SyncConfiguration.where(
          provider: "salesforce",
          account: account,
          object: object,
        )

      each_dead_user_link(api, person_class) do |user, legacy_id, guided_id|
        user_id = user.id
        DistributedMutex.synchronize(
          "salesforce_person_create_#{user_id}",
          validity: ConfiguredUserSync::SYNC_LOCK_VALIDITY,
        ) do
          UserCustomField.transaction do
            removed_fields = 0
            if legacy_id
              removed_fields =
                UserCustomField.where(
                  user_id: user_id,
                  name: person_class::ID_FIELD,
                  value: legacy_id,
                ).delete_all
            end
            removed_link = false
            if guided_id
              removed_link =
                DiscourseCrm::RecordLink.unlink!(
                  provider: "salesforce",
                  account: account,
                  object: object,
                  user_id: user_id,
                  external_id: guided_id,
                )
            end
            next unless removed_fields > 0 || removed_link

            count += 1
            DiscourseCrm::SyncState.where(
              configuration_id: configuration_ids.select(:id),
              user_id: user_id,
            ).update_all(fingerprint: nil)
            if person_class == Contact && removed_fields > 0 && person_class.group.present? &&
                 !UserCustomField.exists?(user_id: user_id, name: person_class::ID_FIELD)
              person_class.group.bulk_remove([user_id])
            end
          end
        end
      end

      count
    end

    def self.each_dead_user_link(api, person_class)
      account = SiteSetting.salesforce_instance_url
      legacy_user_ids = UserCustomField.where(name: person_class::ID_FIELD).select(:user_id)
      configured_ids =
        DiscourseCrm::RecordLink
          .within(provider: "salesforce", account: account, object: person_class::OBJECT_NAME)
          .live
          .select(:user_id)
      linked_users =
        User.where("users.id IN (#{legacy_user_ids.to_sql} UNION #{configured_ids.to_sql})")
      linked_users.in_batches(of: BATCH_SIZE) do |batch|
        users = batch.select(:id, :username).to_a
        user_ids = users.map(&:id)
        legacy_ids =
          UserCustomField
            .where(user_id: user_ids, name: person_class::ID_FIELD)
            .pluck(:user_id, :value)
            .group_by(&:first)
            .transform_values { |rows| rows.map(&:last).uniq }
        links =
          DiscourseCrm::RecordLink.read_many(
            provider: "salesforce",
            account: account,
            object: person_class::OBJECT_NAME,
            user_ids: user_ids,
          )
        guided_ids =
          links
            .filter_map { |user_id, link| [user_id, link.external_id] unless link.converted? }
            .to_h
        dead_values =
          dead_ids(api, person_class::OBJECT_NAME, legacy_ids.values.flatten + guided_ids.values)
        users.each do |user|
          dead_legacy_ids = Array(legacy_ids[user.id]).select { |id| dead_values.include?(id) }
          guided_id = dead_values.include?(guided_ids[user.id]) ? guided_ids[user.id] : nil
          next if dead_legacy_ids.empty? && !guided_id

          yield user, dead_legacy_ids.shift, guided_id
          dead_legacy_ids.each { |id| yield user, id, nil }
        end
      end
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
        dead_ids.concat(dead_in_slice(api, object_name, slice))
      end

      dead_ids
    end

    def self.dead_in_slice(api, object_name, slice)
      records = api.get("composite/sobjects/#{object_name}?fields=Id&ids=#{slice.join(",")}")
      if !records.is_a?(Array) || records.length != slice.length
        raise InvalidApiResponse, "Unexpected Salesforce #{object_name} lookup response"
      end

      slice
        .zip(records)
        .filter_map do |id, record|
          if record.nil?
            id
          elsif !matching_id?(record["Id"], id)
            raise InvalidApiResponse, "Unexpected Salesforce #{object_name} lookup record"
          end
        end
    rescue InvalidApiResponse => error
      # ID_PATTERN cannot see the checksum Salesforce validates, and one
      # rejected ID fails its whole batch; split to isolate the offenders.
      raise if !error.message.include?("MALFORMED_ID")
      return slice if slice.length == 1

      slice
        .each_slice((slice.length / 2.0).ceil)
        .flat_map { |half| dead_in_slice(api, object_name, half) }
    end
    private_class_method :dead_in_slice

    def self.matching_id?(returned_id, requested_id)
      ID_PATTERN.match?(returned_id.to_s) && returned_id.first(15) == requested_id.first(15)
    end
    private_class_method :matching_id?
  end
end
