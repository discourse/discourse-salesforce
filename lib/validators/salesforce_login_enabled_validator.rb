# frozen_string_literal: true

class SalesforceLoginEnabledValidator
  def initialize(opts = {})
    @opts = opts
  end

  def valid_value?(val)
    return true if val == "f"
    if SiteSetting.salesforce_client_id.blank? || SiteSetting.salesforce_client_secret.blank?
      return false
    end
    true
  end

  def error_message
    I18n.t("site_settings.errors.salesforce_client_credentials_required")
  end
end
