# frozen_string_literal: true

module DiscourseCrm
  class SegmentMember < ActiveRecord::Base
    self.table_name = "crm_segment_members"

    belongs_to :segment, class_name: "DiscourseCrm::Segment"
    belongs_to :user
  end
end

# == Schema Information
#
# Table name: crm_segment_members
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  segment_id :bigint           not null
#  user_id    :integer          not null
#
# Indexes
#
#  index_crm_segment_members_on_segment_id_and_user_id  (segment_id,user_id) UNIQUE
#  index_crm_segment_members_on_user_id                 (user_id)
#
