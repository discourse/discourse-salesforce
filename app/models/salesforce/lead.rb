# frozen_string_literal: true

module ::Salesforce
  class LeadConversionReconciliationError < StandardError
  end

  class Lead < Person
    ID_FIELD = "salesforce_lead_id"
    DEFAULT_COMPANY_NAME = "None"
    OBJECT_NAME = "Lead"
    REQUIRED_MAPPING_FIELDS = %w[LastName Company].freeze

    def self.create!(user)
      return unless Salesforce.leads_enabled?

      Salesforce.seed_groups! if group.blank?
      super
    end

    def self.group
      Salesforce.leads_group
    end

    def self.payload(user)
      user.salesforce_lead_payload
    end

    def self.find_converted_by_email(email, api: Salesforce.api)
      escaped_email = escape_soql_string(email)
      result =
        api.query(
          "SELECT Id, IsConverted, ConvertedContactId FROM Lead WHERE Email = '#{escaped_email}' AND IsConverted = true",
        )
      return if result["totalSize"] == 0
      raise AmbiguousEmailMatch.new(OBJECT_NAME) if result["totalSize"] > 1

      result.fetch("records").first
    end

    def self.sync(user)
      return true if super

      converted_lead = find_converted_by_email(user.email)
      return false unless converted_lead

      contact_id = converted_lead["ConvertedContactId"]
      if contact_id.blank?
        Rails.logger.warn(
          "Skipping replacement Lead creation for Discourse user #{user.id}: converted Salesforce Lead #{converted_lead["Id"]} has no Contact ID",
        )
        return true
      end

      existing_contact_id = user.salesforce_contact_id
      if existing_contact_id.present? && existing_contact_id != contact_id
        Rails.logger.warn(
          "Skipping converted Salesforce Lead reconciliation for Discourse user #{user.id}: an existing Contact link conflicts",
        )
        return true
      end

      scope = {
        provider: "salesforce",
        account: SiteSetting.salesforce_instance_url,
        user_id: user.id,
      }
      contact_link = Salesforce::RecordLink.new(**scope, object: "Contact").read
      if contact_link &&
           (contact_link["account"] != scope[:account] || contact_link["id"] != contact_id)
        Rails.logger.warn(
          "Skipping converted Salesforce Lead reconciliation for Discourse user #{user.id}: an existing Contact link conflicts",
        )
        return true
      end

      lead_link = Salesforce::RecordLink.new(**scope, object: "Lead").read
      if lead_link &&
           (lead_link["account"] != scope[:account] || lead_link["id"] != converted_lead["Id"])
        Rails.logger.warn(
          "Skipping converted Salesforce Lead reconciliation for Discourse user #{user.id}: an existing Lead link conflicts",
        )
        return true
      end

      Salesforce::RecordLink.new(**scope, object: "Lead").mark_converted_to(contact_id)
      Salesforce::RecordLink.new(**scope, object: "Contact").write(
        contact_id,
        converted_from_lead_id: converted_lead["Id"],
      )
      user.salesforce_lead_id = nil if user.salesforce_lead_id == converted_lead["Id"]
      user.salesforce_contact_id = contact_id
      user.save_custom_fields
      true
    end
  end
end
