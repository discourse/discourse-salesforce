# frozen_string_literal: true

module DiscourseCrm
  module UserEmailExtension
    extend ActiveSupport::Concern

    included do
      after_destroy { SyncAttempt.scrub_rejected_values(user_id, email: email) }
      after_update do
        if saved_change_to_email? || saved_change_to_user_id?
          SyncAttempt.scrub_rejected_values(user_id_before_last_save, email: email_before_last_save)
        end
      end
    end
  end
end
