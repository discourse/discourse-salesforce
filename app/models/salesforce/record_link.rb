# frozen_string_literal: true

module Salesforce
  class RecordLink
    def initialize(provider:, account:, object:, user_id:)
      @provider = provider
      @account = account
      @object = object
      @user_id = user_id
    end

    def read
      link = PluginStore.get(PLUGIN_NAME, key)
      return link if link
      return unless @provider == "salesforce"

      legacy = PluginStore.get(PLUGIN_NAME, "configured_user_link:#{@object}:#{@user_id}")
      return unless legacy

      # Preserve the account so callers reject links belonging to another instance.
      { "id" => legacy.fetch("id"), "account" => legacy.fetch("instance") }
    end

    def write(id, converted_from_lead_id: nil)
      existing = PluginStore.get(PLUGIN_NAME, key)
      if existing && existing["id"] == id
        converted_from_lead_id ||= existing["converted_from_lead_id"]
      end
      value = { "id" => id, "account" => @account }
      value["converted_from_lead_id"] = converted_from_lead_id if converted_from_lead_id
      PluginStore.set(PLUGIN_NAME, key, value)
    end

    def mark_converted_to(contact_id)
      PluginStore.set(
        PLUGIN_NAME,
        key,
        { "account" => @account, "converted_to" => { "object" => "Contact", "id" => contact_id } },
      )
      if @provider == "salesforce"
        PluginStore.remove(PLUGIN_NAME, "configured_user_link:#{@object}:#{@user_id}")
      end
    end

    private

    def key
      scope = Digest::SHA256.hexdigest([@provider, @account, @object, @user_id].to_json)
      "record_link:#{scope}"
    end
  end
end
