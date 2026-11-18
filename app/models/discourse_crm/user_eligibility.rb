# frozen_string_literal: true

module DiscourseCrm
  class UserEligibility
    def self.eligible_users
      users = User.activated.human_users.not_staged.not_suspended
      if SiteSetting.allow_anonymous_mode
        users =
          users.where.not(
            id: User.joins(:anonymous_user_master).where("trust_level >= 1").select(:id),
          )
      end
      users
    end

    def self.eligible_group_members(group_ids)
      eligible_users.where(id: GroupUser.where(group_id: group_ids).select(:user_id))
    end

    def self.auto_create_eligible?(user)
      user.active? && user.human? && !user.anonymous? && !user.staged? && !user.suspended?
    end

    def self.email_verified?(user)
      return false unless user.active? && !user.staged?
      return user.email_confirmed? unless user.association(:email_tokens).loaded?

      # Match User#email_confirmed? without querying the preloaded association again.
      user.email_tokens.empty? ||
        user.email_tokens.any? { |token| token.confirmed? && token.email == user.email } ||
        user.single_sign_on_record&.external_email&.downcase == user.email
    end
  end
end
