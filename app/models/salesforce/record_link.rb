# frozen_string_literal: true

module Salesforce
  class RecordLink
    def self.read_many(provider:, account:, object:, user_ids:)
      ids = user_ids.uniq
      current_keys = ids.to_h { |user_id| [user_id, key(provider, account, object, user_id)] }
      stored = PluginStore.get_all(PLUGIN_NAME, current_keys.values)
      ids.to_h { |user_id| [user_id, stored[current_keys[user_id]]] }
    end

    def initialize(provider:, account:, object:, user_id:)
      @provider = provider
      @account = account
      @object = object
      @user_id = user_id
    end

    def read
      PluginStore.get(PLUGIN_NAME, key)
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

    def remove(id)
      link = read
      return false unless link && link["id"] == id && link["account"] == @account

      PluginStore.remove(PLUGIN_NAME, key)
      true
    end

    def mark_converted_to(contact_id)
      PluginStore.set(
        PLUGIN_NAME,
        key,
        { "account" => @account, "converted_to" => { "object" => "Contact", "id" => contact_id } },
      )
    end

    private

    def key
      self.class.send(:key, @provider, @account, @object, @user_id)
    end

    def self.key(provider, account, object, user_id)
      scope = Digest::SHA256.hexdigest([provider, account, object, user_id].to_json)
      "record_link:#{scope}"
    end
    private_class_method :key
  end
end
