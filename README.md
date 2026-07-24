## Discourse Salesforce Plugin

For more information, please see: https://meta.discourse.org/t/discourse-salesforce/218267

### Updating existing Salesforce users

When a Discourse user is created, the plugin links them to an existing Salesforce Contact or Lead
with the same email address. By default, it does not update the Salesforce record. Enable the
`salesforce_fill_blank_fields_on_user_sync` site setting to use fill-only synchronization:

- A blank `LeadSource` is set to `Web`.
- A blank `Description` is set to the Discourse user profile URL.
- `Email` is only used to find the record and is not included in the update payload.
- Existing non-empty Salesforce values are never overwritten.

When the setting is enabled, plugins can customize the fields with a modifier:

```ruby
register_modifier(:salesforce_existing_user_sync_payload) do |
  payload,
  user,
  object_name
|
  custom_payload = payload.dup
  custom_payload[:CustomField__c] = user.username if object_name == "Contact"
  custom_payload
end
```

The modifier receives the default two-field payload, the Discourse user, and the Salesforce object
name. Modifier-added fields use the same fill-only behavior. The modifier is not called when the
site setting is disabled.
