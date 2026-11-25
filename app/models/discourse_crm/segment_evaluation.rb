# frozen_string_literal: true

module DiscourseCrm
  class SegmentEvaluation
    PAGE_SIZE = 1000
    PREVIEW_USERNAMES = 8

    def self.run_page(provider:, account:, after: nil)
      new(provider:, account:).run_page(after)
    end

    def self.run_for_users(provider:, account:, user_ids:)
      new(provider:, account:).run_for_users(user_ids)
    end

    def self.preview(segment)
      new(provider: segment.provider, account: segment.account).preview(segment)
    end

    def initialize(provider:, account:)
      @provider = provider
      @account = account
    end

    def run_page(after)
      return if segments.empty?
      user_ids = linked_user_ids.where("user_id > ?", after.to_i).limit(PAGE_SIZE).pluck(:user_id)
      evaluate(user_ids) if user_ids.any?
      return user_ids.last if user_ids.size == PAGE_SIZE
      finish
      nil
    end

    def run_for_users(user_ids)
      evaluate(user_ids)
    end

    def preview(segment)
      total = 0
      count = 0
      usernames = []
      after = 0
      loop do
        user_ids = linked_user_ids.where("user_id > ?", after).limit(PAGE_SIZE).pluck(:user_id)
        break if user_ids.empty?
        eligible = eligible_ids(user_ids)
        records = records_by_user(user_ids)
        total += eligible.size
        matched = eligible.select { |user_id| segment.matches?(records.fetch(user_id, [])) }
        count += matched.size
        if usernames.size < PREVIEW_USERNAMES
          usernames +=
            User.where(id: matched.first(PREVIEW_USERNAMES - usernames.size)).pluck(:username)
        end
        after = user_ids.last
        break if user_ids.size < PAGE_SIZE
      end
      { count:, total:, usernames: }
    end

    private

    def segments
      @segments ||=
        begin
          pulled = Segment.pulled_properties(provider: @provider, account: @account)
          Segment
            .within(provider: @provider, account: @account)
            .order(:id)
            .reject { |segment| segment.missing_properties(pulled).any? }
        end
    end

    def linked_user_ids
      RecordLink
        .where(provider: @provider, account: @account, direction: "inbound")
        .select(:user_id)
        .distinct
        .order(:user_id)
    end

    def eligible_ids(user_ids)
      UserEligibility.eligible_users.where(id: user_ids).order(:id).pluck(:id)
    end

    def records_by_user(user_ids)
      RecordLink
        .where(provider: @provider, account: @account, direction: "inbound", user_id: user_ids)
        .includes(record: :company)
        .group_by(&:user_id)
        .transform_values { |links| links.filter_map(&:record) }
    end

    def evaluate(user_ids)
      return if segments.empty?
      eligible = eligible_ids(user_ids)
      records = records_by_user(eligible)
      now = Time.zone.now
      segments.each do |segment|
        matched = eligible.select { |user_id| segment.matches?(records.fetch(user_id, [])) }
        unmatched = user_ids - matched
        if matched.any?
          SegmentMember.insert_all(
            matched.map { |user_id| { segment_id: segment.id, user_id:, created_at: now } },
            unique_by: %i[segment_id user_id],
          )
        end
        segment.members.where(user_id: unmatched).delete_all if unmatched.any?
        apply_to_group(segment, matched, unmatched)
      end
    end

    def apply_to_group(segment, matched, unmatched)
      group = Group.find_by(id: segment.group_id)
      return if group.nil?
      current = GroupUser.where(group_id: group.id, user_id: matched + unmatched).pluck(:user_id)
      to_add = matched - current
      group.bulk_add(to_add, automatic: true) if to_add.any?
      return unless segment.remove_unmatched
      to_remove = unmatched & current
      group.bulk_remove(to_remove) if to_remove.any?
    end

    def finish
      return if segments.empty?
      SegmentMember
        .where(segment_id: segments.map(&:id))
        .where.not(user_id: linked_user_ids.unscope(:order))
        .or(
          SegmentMember.where(segment_id: segments.map(&:id)).where.not(user_id: User.select(:id)),
        )
        .delete_all
      segments.each { |segment| reconcile_group(segment) }
      Segment.where(id: segments.map(&:id)).update_all(last_evaluated_at: Time.zone.now)
    end

    def reconcile_group(segment)
      group = Group.find_by(id: segment.group_id)
      return if group.nil?
      group_user_ids = GroupUser.where(group_id: group.id).select(:user_id)
      each_batch(segment.members.where.not(user_id: group_user_ids)) do |user_ids|
        group.bulk_add(user_ids, automatic: true)
      end
      return unless segment.remove_unmatched
      each_batch(
        GroupUser.where(group_id: group.id).where.not(user_id: segment.members.select(:user_id)),
      ) { |user_ids| group.bulk_remove(user_ids) }
    end

    def each_batch(scope)
      previous = nil
      loop do
        user_ids = scope.order(:user_id).limit(PAGE_SIZE).pluck(:user_id)
        break if user_ids.empty? || user_ids == previous
        yield user_ids
        previous = user_ids
      end
    end
  end
end
