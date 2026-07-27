## Discourse Salesforce Plugin

For more information, please see: https://meta.discourse.org/t/discourse-salesforce/218267

### Updating existing Salesforce users

When a Discourse user is created, the plugin links them to an existing Salesforce Contact or Lead
with the same email address. By default, it does not update the Salesforce record. Enable the
`salesforce_existing_record_sync_mode` site setting to choose how an existing Contact's
`Description` is synchronized:

- `link_only` only links the matching record and does not update it.
- `fill_blank` sets a blank `Description` to the Discourse user profile URL. An existing non-empty
  description is preserved.
- `overwrite` replaces `Description` with the Discourse user profile URL.
- `Email` is only used to find the record and is not included in the default update payload.

Leads are linked but never updated. If multiple Contacts have the same email, the plugin skips
linking and updating the ambiguous records when `fill_blank` or `overwrite` is selected.
