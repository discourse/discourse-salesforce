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

### Experimental user sync configurations

Enable `salesforce_enabled` and opt into `enable_salesforce_configurations` under
Admin → Upcoming changes. Configure the existing JWT API credentials, then open
`/admin/plugins/discourse-salesforce/configurations`.

Saving a user configuration validates its fields against Salesforce and activates
real Lead or Contact sync for the selected group. Previously saved demo configurations
remain inactive until saved again. The confirmation preview is an illustrative sample;
it does not read a member's Salesforce record or make writes itself.

- Backfill queues existing group members on first activation, when enabled again, or
  when changing the selected group. It runs in batches of 100, with one job per user.
- Group joins and profile changes enqueue sync when their corresponding options are
  enabled. Jobs re-read the configuration and membership before executing. Inactive,
  staged, anonymous, suspended, and system users are excluded. Group counters and
  backfill batches use the same eligibility rules; groups with no eligible members show zero.
- Scheduled refreshes run hourly, daily at 02:00 UTC, or Mondays at 02:00 UTC through
  the hourly scheduler. Manual disables scheduled refresh. Sidekiq must be running.
- Disabling the experimental flag or deleting a configuration stops pending/future
  configuration jobs. An already-running HTTP request may finish. Salesforce records
  and stable record links are never deleted.

`Jobs::SyncSalesforceUser` dispatches configuration jobs to
`Salesforce::ConfiguredUserSync`, reusing the API client, Person email lookup, and
Lead/Contact definitions. It does not change legacy global sync settings or case jobs.
No Workflows dependency or core changes are required. Sync posts is Coming soon.

Email is matched within the selected object. Multiple matches fail without writing.
Successful matching/creation retains an object/user link in PluginStore, pinned to the
Salesforce instance, so email changes do not create a second record. Email is sent only
on creation. Missing/deleted/converted linked records require administrator review;
they are not silently recreated. A local distributed mutex serializes writes per user.
A remote create followed by a local failure is reconciled by email on retry; exact
once-only creation cannot be guaranteed against concurrent external writers.

Each mapping preserves nonempty Salesforce values or overwrites them as selected.
Empty Discourse values never clear a Salesforce field. New records use Discourse values.
Names use the existing plugin splitting rules, including a last-name fallback for
single-word names. Company reads the custom profile field named Company (case-insensitive),
falling back to `None`. LeadSource is currently fixed to Community. Administrators must
map values accepted by their org's picklists and validation rules; Salesforce rejects
invalid payloads and the job records the failure. No implicit AccountId lookup occurs.
The available source list remains limited to the wizard's current fields.

All-time posts use UserStat; 30-day posts count nondeleted regular posts on regular
topics; group membership includes the user's group names. Last seen uses last_seen_at.
Custom field mappings target real Salesforce field API names and are validated on save
and execution. Unsupported types and duplicate destinations are rejected server-side.

Configuration jobs retry failures five times. The list shows Active, Inactive, or a
sync failure indicator on reload. Error class, affected user ID, and timestamps are
stored in `configuration_status:<id>`; background job failures are inspectable in
Sidekiq. This is a last-error summary, not a full per-user run history. A successful
retry for that user clears the error. Mapping changes require saving the configuration;
queued jobs always use the latest saved mappings.

The Configurations tab clears selection and returns to the list. Successful saves
return there with a toast. Wizard forms keep stable FormKit data to preserve focus.
