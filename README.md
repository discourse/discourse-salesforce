## Discourse Salesforce Plugin

For more information, please see: https://meta.discourse.org/t/discourse-salesforce/218267

### Updating existing Salesforce users

When a Discourse user is created, the plugin links them to an existing Salesforce Contact or Lead
with the same email address. By default, it does not update the Salesforce record. Enable the
`salesforce_existing_record_sync_mode` site setting to choose how fields are synchronized:

- `link_only` only links the matching record and does not update it.
- `fill_blank` sets a blank `LeadSource` to `Web` and a blank `Description` to the Discourse user
  profile URL. Existing non-empty Salesforce values are preserved.
- `overwrite` replaces `LeadSource` and `Description` with those values.
- `Email` is only used to find the record and is not included in the default update payload.

When the mode is `fill_blank` or `overwrite`, plugins can customize the fields with a modifier:

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
name. Modifier-added fields follow the selected update mode, but `nil` and empty values are never
sent to Salesforce. The modifier is not called when the mode is `link_only`.

If multiple Contacts or multiple Leads have the same email, the plugin skips linking and updating
the ambiguous records when `fill_blank` or `overwrite` is selected.
