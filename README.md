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

Lead lookups, creation, conversion sync, and feed items are enabled when
`salesforce_lead_source` is nonblank or the group identified by `salesforce_leads_group_id` has
at least one member. The default source, `Web`, preserves existing Lead behavior, including
signup matching on sites with an empty Leads group.

To disable all Lead operations, clear `salesforce_lead_source` and empty the Salesforce Leads
group. Removing the group also counts as empty. Either a nonblank source or any group member
keeps Leads enabled for all users. Disabling Leads retains existing Lead links and skips manual
creation. Contact operations continue, although clearing the source also omits the `LeadSource`
field from Contact payloads.

Leads are linked but never updated. If multiple Contacts have the same email, the plugin skips
linking and updating the ambiguous records when `fill_blank` or `overwrite` is selected.

### Reconnecting Salesforce

After connecting Discourse to a different Salesforce organization or refreshing a sandbox, run
`bin/rake salesforce:prune_dead_associations`. The task removes local Contact, Lead, Case, and Case
Comment references that the connected integration user cannot resolve. Assign the integration
user full record-level read access to Contact, Lead, and Case records before running it.

When `salesforce_lead_source` is blank and the Salesforce Leads group has no members, the task
skips Lead reporting and cleanup, retaining existing Lead links. Pruning stale Lead links
preserves Leads group membership so cleanup does not turn off Lead operations. Contact group
memberships are still removed when their Contact links are pruned.
