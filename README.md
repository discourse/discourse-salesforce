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

### Unlinking cases

`salesforce_case_unlink_allowed_groups` controls who can unlink cases. It defaults to empty,
which disables unlinking for everyone, including admins. The fixed list offers only Admins and
Moderators; select either or both to grant access. They must also be able to see the topic.

Open the first post’s **wrench** menu and choose **Unlink case** to remove the Discourse case and
comment links after confirmation. The case and its comments remain in Salesforce. Unlinking
only changes local data and works even when Salesforce credentials are unavailable.

Unlinking also removes the configured case tag, enabled case status tags, and automatic case
sync trigger tags from the topic so subsequent edits do not create another case. Already queued
automatic sync jobs skip creating a case once its trigger tags and local association are gone.
Other tags and the Discourse topic remain. This action is separate from create/sync permissions.

### Reconnecting Salesforce

After connecting Discourse to a different Salesforce organization or refreshing a sandbox, run
`bin/rake salesforce:prune_dead_associations`. The task removes local Contact, Lead, Case, and Case
Comment references that the connected integration user cannot resolve. Assign the integration
user full record-level read access to Contact, Lead, and Case records before running it.

When `salesforce_leads_enabled` is disabled, the task skips Lead reporting and cleanup, retaining
existing Lead links. Pruning stale Lead links preserves Leads group membership. Contact group
memberships are still removed when their Contact links are pruned.

### Experimental user sync configurations

Enable `salesforce_enabled` and opt into `enable_guided_sync_configuration` under
Admin → Upcoming changes. Configure the existing JWT API credentials, then open
`/admin/plugins/discourse-salesforce/configurations`.

Saving a user configuration validates its fields against Salesforce and activates
real Lead or Contact sync for members of any selected group. Previously saved demo configurations
remain inactive until saved again. The preview section compares real Discourse member values with sample Salesforce values without reading or writing Salesforce records.

- Backfill queues existing group members on first activation, when enabled again, or
  when changing the selected groups. It queues one batch job per 100 eligible users. Scheduled refreshes use the same path.
- Group joins and profile changes always enqueue sync for active configurations. Jobs re-read the configuration and membership before executing. Inactive,
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
There is no Workflows dependency. The group picker uses the optional core `DMultiSelect`
footer slot for group creation. Sync posts is Coming soon.

Email is matched within the selected object. Multiple matches fail without writing.
Successful matching/creation retains an object/user link in PluginStore, pinned to the
Salesforce instance, so email changes do not create a second record. Email is sent only
on creation. Confirmed deleted, unconverted Leads can be recreated; missing or
inaccessible records without confirmed deletion remain errors. A local distributed mutex serializes writes per user.
A remote create followed by a local failure is reconciled by email on retry; exact
once-only creation cannot be guaranteed against concurrent external writers.

Each mapping preserves nonempty Salesforce values or overwrites them as selected.
Empty Discourse values never clear a Salesforce field. New records use Discourse values.
Names use the existing plugin splitting rules, including a last-name fallback for
single-word names. New Lead configurations map editable static text `Unknown` to Company.
Legacy Company mappings retain their custom-field lookup and `None` fallback. LeadSource
can be mapped to optional static text. Administrators must
map values accepted by their org's picklists and validation rules; Salesforce rejects
invalid payloads and the job records the failure. No implicit AccountId lookup occurs.
Configured custom user fields are available as mapping sources; internal custom-field keys are not exposed.

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
return there with a toast. Configuration forms keep stable FormKit data to preserve focus.

Use **Add field**, then choose **Static text** as a mapping source to send a constant string, such as `Discourse`
to `LeadSource`. Static values must contain 1–1,000 characters and use the same
keep/overwrite rules as other mappings. Choose Discourse under **Keep value from**
to replace an existing Salesforce value.
Existing fixed Community mappings open as editable static text with their value preserved.

When Salesforce confirms a linked Lead was deleted (and not converted), sync matches
by email again and creates a replacement if no active match exists. Missing or
inaccessible records without confirmed deletion remain errors.

### Batch syncing

`Jobs::SyncSalesforceUserBatch` uses `Salesforce::ConfiguredUserBatchSync` for backfills
and scheduled refreshes. Each batch fetches Describe metadata once, queries records
in groups of 25 (following Salesforce query pagination), and sends separate create
and update requests to the sObject Collections endpoint with `allOrNone: false`.
Unchanged records require no write. Each successful result saves its stable record link.

Per-user creation locks are acquired in ID order and shared with individual sync jobs.
Ambiguous matches, missing links, and failed collection entries fall back to individual
jobs, preserving deleted-Lead recovery and the existing retry limit. An uncertain HTTP
write response also falls back to email/ID reconciliation before retrying. Group joins
and profile changes continue to use individual REST requests. This uses synchronous
sObject Collections, not the asynchronous Bulk API 2.0.

### Member previews

The preview section below field mapping automatically previews the first eligible member (ordered by username). Administrators
can search eligible members of the selected groups and preview unsaved mappings for another
member. Discourse values come from the selected member; Salesforce values are examples,
clearly labeled in the UI. Preview loads Salesforce field metadata to validate mappings and
format values, but does not look up Salesforce records or stored record links. It applies
the same mapping conversions and ownership rules as sync without writing records or sync
status. A selection with no eligible members shows clearly labeled sample data. Sample values
illustrate field ownership and are not a prediction of the member's actual Salesforce record.

### Stored activity and custom user fields

Mapping sources include all-time read time (minutes, rounded to two decimal places),
posts read, topics entered, likes given/received, and days visited from UserStat.
These are stored totals; this does not add 30-day versions of these metrics.

Configured UserField definitions are discovered when loading or refreshing the field list.
Mappings use stable user_field_ID identifiers so renaming a field preserves the mapping;
deleting a field makes it invalid on the next validation. Text and dropdown fields map to
text, confirmation fields to Salesforce booleans, and date fields to date/datetime destinations.
Multi-select values are joined with semicolons for Salesforce multipicklists and commas for
other text fields. Missing values do not clear Salesforce fields. False and zero are preserved.

Batch jobs load only selected UserStat columns and configured custom-field values for all users
together. Preview and single-user jobs use the same value conversion.

Bio and Website are optional text sources from UserProfile. Bio uses the stored raw text
(including Markdown), not rendered HTML. Blank profile values do not clear Salesforce fields.
Selected profile columns are loaded once per batch. The Discourse source picker supports
search by label and groups sources into User details, Activity, and Custom fields.

Sync configurations can select multiple groups. Membership uses the union of those groups;
backfill and scheduled batches deduplicate users before paging. A user remains eligible until
they leave every selected group. Existing single-group configurations remain supported and
are stored with group arrays when next saved. The group picker reloads available groups when
searching. The group picker’s “Create a group” footer action opens a small modal using the core group endpoint and selects the new group
without leaving the configuration page. Groups are invite-only, with group-owner visibility for both the group and its member list.
Mentions, messages, and assignment levels are set to nobody. Membership requests and public
joining/leaving are disabled. Groups remain available if the sync setup is canceled;
membership is managed from Groups.

When selected groups have no eligible users, the preview section shows a clearly labeled sample user
using generated Discourse values and sample Salesforce values. Static mapping values still
come from the configuration, and the normal mapping and ownership rules apply. No user is
created or saved. Errors fetching preview data remain errors rather than using sample data.

Group joins and profile changes always trigger syncing for active configurations; the old
onJoin/onChange options are ignored. Backfill and the activity refresh schedule remain optional.
After a successful individual sync, a digest of mapped values and mapping settings lets
unchanged profile-change jobs return before contacting Salesforce. Scheduled and group-join
syncs still check Salesforce. Failed attempts never advance the digest, so retries remain valid.

The configuration editor is a single page: group/object selection, sync behavior, and field
mapping, followed by a separate preview section with a user selector and comparison table. Salesforce metadata loads on entry and when the target object
changes. Group and mapping edits invalidate old preview results and debounce a new preview;
request counters discard late responses. Invalid mappings block saving and preview requests.
Preview failures offer a retry without blocking an otherwise valid configuration from saving.

New Lead configurations explicitly map static text `Unknown` to Salesforce `Company`,
preserving non-empty Salesforce values by default. Admins can edit the text or select any
compatible source, including a configured custom user field named Company. Contacts do not
receive this default mapping. The legacy Company source remains supported only for existing
mappings, preserving their custom-field lookup and `None` fallback until an admin remaps them.

### Provider boundaries

Configurations persist a `provider` identity; existing records default to `salesforce`.
Only Salesforce configurations are handled by the current jobs. Authentication, object
requirements, field conversion, matching and API batching remain Salesforce-specific.

`UserSyncSources` loads Discourse values independently of destination field names and
formats. It batches profile, statistics, custom field, group membership and recent post
queries. Salesforce serialization and legacy Company/LeadSource defaults live in `FieldMapping`,
which is shared by sync execution and preview rather than the source loader.

`RecordLink` scopes a remote ID by provider, account, object and Discourse user. Salesforce
currently uses its instance URL as the account identity. Existing configured links remain
readable, including their original instance guard. New writes use the scoped key. The
PluginStore namespace remains `discourse-salesforce`; a future plugin rename must preserve
or migrate that namespace. User custom fields remain compatibility fields for legacy
Salesforce features, not the provider-independent link store.

Reconciliation updates configured Contact links after merges and establishes Contact links
for converted Leads with a matching configured link. The original Lead link is retained:
a Lead configuration is never silently redirected to the Contact object. These boundaries
prepare for another provider without defining a shared API adapter prematurely.

`ConfigurationScheduler` owns event-triggered enqueueing, activation backfills and periodic
refresh scheduling. `GuidedSyncConfiguration` retains validation and persistence. Scheduling
continues to use the existing timestamps and locks, so extracting it does not reset due dates.

`UserSyncPreview` owns sample records and comparison rows. `FieldMapping` evaluates both
preview and real payloads, including ownership rules, writable fields and type conversion.
Preview only requests object metadata; it does not read or write Salesforce user records.

Reconciliation reloads user custom fields under the same per-user lock as sync jobs, then
updates the legacy ID and configured link within one database transaction. A failed link
write rolls back the legacy update, and stale responses cannot overwrite a newer legacy ID.

Configuration endpoints return translated authentication, permission, request-limit,
temporary-connection or unexpected-response errors. Diagnostic logs include the operation,
category and HTTP status, excluding upstream bodies, credentials and request headers.
