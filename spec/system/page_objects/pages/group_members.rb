# frozen_string_literal: true

module PageObjects
  module Pages
    class GroupMembers < PageObjects::Pages::Group
      def has_member?(user)
        has_css?(".directory-table__row", text: user.username)
      end

      def has_no_member?(user)
        has_no_css?(".directory-table__row", text: user.username)
      end
    end
  end
end
