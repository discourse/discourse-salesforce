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

Lead lookups, creation, conversion sync, feed items, and association cleanup are controlled by
`salesforce_leads_enabled`, which defaults to `true` to preserve existing behavior.

For Contact-only integrations or Salesforce organizations where the integration user cannot
access Leads, disable `salesforce_leads_enabled`. Existing Lead links are retained and Contact
operations continue. Lead enablement is independent of Leads group membership and
`salesforce_lead_source`; leaving the source blank only omits `LeadSource` from payloads.

Leads are linked but never updated. If multiple Contacts have the same email, the plugin skips
linking and updating the ambiguous records when `fill_blank` or `overwrite` is selected.

### Creating and syncing cases

Only admins can create and manually sync Salesforce cases by default. Enable
`salesforce_allow_moderators_to_create_cases` to allow moderators to perform these actions
for topics they can see. Both actions use the site's Salesforce integration credentials.
This setting does not affect automatic case synchronization through
`salesforce_automatic_case_sync_tags` or grant access to Salesforce configuration or manual
Contact/Lead creation.

### Deleting cases

`salesforce_case_deletion_allowed_groups` controls who can delete cases. It defaults to empty,
which disables deletion for everyone, including admins. Add the admins, moderators, or custom
groups that should have access. Members must also be able to see the topic.

The **Delete case** button beside the case details asks for confirmation, deletes the case in
Salesforce using the integration account, and removes the Discourse case and comment links.
The integration account needs permission to delete Cases. If Salesforce rejects deletion,
Discourse keeps the association intact.

Deletion also removes the configured case tag, enabled case status tags, and automatic case
sync trigger tags from the topic so subsequent edits do not recreate the case. Other tags remain.
It does not delete the Discourse topic. This action is separate from create/sync permissions.

### Reconnecting Salesforce

After connecting Discourse to a different Salesforce organization or refreshing a sandbox, run
`bin/rake salesforce:prune_dead_associations`. The task removes local Contact, Lead, Case, and Case
Comment references that the connected integration user cannot resolve. Assign the integration
user full record-level read access to Contact, Lead, and Case records before running it.

When `salesforce_leads_enabled` is disabled, the task skips Lead reporting and cleanup, retaining
existing Lead links. Pruning stale Lead links preserves Leads group membership. Contact group
memberships are still removed when their Contact links are pruned.
