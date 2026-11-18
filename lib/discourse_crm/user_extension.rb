# frozen_string_literal: true

module DiscourseCrm
  module UserExtension
    extend ActiveSupport::Concern

    prepended do
      has_many :crm_record_links, class_name: "DiscourseCrm::RecordLink"
      has_many :crm_records,
               -> { where(crm_record_links: { direction: "inbound" }) },
               through: :crm_record_links,
               source: :record
    end
  end
end
