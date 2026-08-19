## Discourse Salesforce Plugin

For more information, please see: https://meta.discourse.org/t/discourse-salesforce/218267

### Updating existing Salesforce users

When a Discourse user is created, the plugin links them to an existing Salesforce Contact or Lead
with the same email address. By default, it does not update the Salesforce record. Enable the
`salesforce_contact_sync_mode` site setting to choose how existing Contact fields selected in
`salesforce_contact_sync_fields` are synchronized. `Description` is selected by default and is set
to the Discourse profile URL:

- `link_only` only links the matching record and does not update it.
- `fill_blank` populates selected fields only when they are empty in Salesforce.
- `overwrite` replaces selected Salesforce field values with values from Discourse.
- `Email` is only used to find the record and is not included in the default update payload.

Leads are linked but never updated. If multiple Contacts have the same email, the plugin skips
linking and updating the ambiguous records when `fill_blank` or `overwrite` is selected.

### Idempotent Salesforce cases

To prevent a retry from creating a duplicate Salesforce Case, add this custom field to the Case
object:

- Field name: `Discourse_Topic_Key` (API name `Discourse_Topic_Key__c`)
- Type: Text, at least 64 characters
- Options: External ID and Unique
- Permissions: read and write access for the Salesforce integration user

The plugin checks the Case metadata and uses the field automatically; there is no Discourse site
setting. The key is a hash of the site's canonical hostname and topic ID, so sites connected to the
same Salesforce organization do not collide. A retry upserts the same Case and refreshes its fields
from the Discourse topic.

If the field is absent or does not have all the required properties, the plugin retains the legacy
Case creation behavior. A transient metadata lookup failure stops Case creation instead of silently
falling back to a non-idempotent request.
