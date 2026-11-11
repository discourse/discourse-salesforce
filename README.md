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

### Unlinking contacts

Staff allowed by `salesforce_contact_unlink_allowed_groups` can choose **Unlink Contact**
in the post admin menu when the post author has a linked Contact. **Create Contact** appears
instead when the author has no linked Contact. The setting defaults to empty, which disables
contact unlinking for everyone, including admins. Select Admins, Moderators, or both
independently of the case unlink setting. Staff must also be able to see the topic.
Confirmation removes the local association and its
matching guided-sync link for the connected Salesforce account. The Salesforce record is retained.
Automatic synchronization may link the user again; unlinking does not opt the user out of sync.

### Creating and syncing cases

Only admins can create and manually sync Salesforce cases by default. Enable
`salesforce_allow_moderators_to_create_cases` to allow moderators to perform these actions
for topics they can see. Both actions use the site's Salesforce integration credentials.
This setting does not affect automatic case synchronization through
`salesforce_automatic_case_sync_tags` or grant access to Salesforce configuration or manual
Contact/Lead creation.

### Unlinking cases

`salesforce_case_unlink_allowed_groups` controls who can unlink cases. It defaults
to empty, which disables unlinking for everyone, including admins. The fixed list offers only Admins and
Moderators; select either or both to grant access. They must also be able to see the topic.

Open the topic’s **wrench** menu and choose **Unlink Case** beside **Sync Case** to remove the
Discourse case and comment links after confirmation. The case and its comments remain in Salesforce. Unlinking
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
memberships are still removed when their Contact links are pruned. Guided sync links are also
checked, including links without a legacy user custom field. Removing a dead guided association
clears its configuration fingerprints for the connected account and object; links in other
accounts and converted-Lead markers are preserved. `DRY_RUN=1` reports the same legacy and guided
user links that cleanup checks, without deleting links or fingerprints. If a user has multiple
legacy ID rows, each ID is checked; live rows and their Contact group membership are preserved.

### Experimental configurations: send users to Salesforce

Guided sync only creates or updates Salesforce records for users whose current email address
passes Discourse's email-verification check. Active accounts with an unconfirmed address are skipped;
confirming the address queues a sync for their selected groups, including manual configurations.

Enable `salesforce_enabled` and opt into `enable_guided_sync_configuration` under
Admin → Upcoming changes. Configure the existing JWT API credentials, then open
`/admin/plugins/discourse-salesforce/configurations`.

Choose **Send users to Salesforce** to create or update Salesforce leads and contacts using
Discourse user data. New configurations default to **Send users**. These configurations send data
from Discourse to Salesforce; they do not import Salesforce fields into Discourse user profiles.
Saving validates the fields against Salesforce and activates updates for members of any selected
group. New configurations with existing-member sending enabled use **Save and send**; otherwise,
the action is **Save configuration**.

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
Successful matching/creation retains an object/user link in the `crm_record_links` table,
pinned to the Salesforce instance, so email changes do not create a second record. Email is sent only
on creation. Confirmed deleted, unconverted Leads can be recreated; missing or
inaccessible records without confirmed deletion remain errors. Converted Leads are
reconciled to their Contact and skipped by Lead configurations. A local distributed mutex serializes writes per user.
A remote create followed by a local failure is reconciled by email on retry; exact
once-only creation cannot be guaranteed against concurrent external writers.

Each mapping preserves nonempty Salesforce values or overwrites them as selected.
Empty Discourse values never clear a Salesforce field. New records use Discourse values.
Names use the existing plugin splitting rules, including a last-name fallback for
single-word names. Blank names fall back to the username. Legacy and configured Lead conversion
reconciliation preserve conflicting existing Lead or Contact associations. New Lead configurations map editable static text `Unknown` to Company.
LeadSource can be mapped to optional static text. Administrators must
map values accepted by their org's picklists and validation rules; Salesforce rejects
invalid payloads and the job records the failure. No implicit AccountId lookup occurs.
Configured custom user fields are available as mapping sources. Other custom fields are only readable through the explicit **User custom field** source, which names the field.

All-time posts use UserStat; 30-day posts count nondeleted regular posts on regular
topics; group membership includes the user's group names. Last seen uses last_seen_at.
Custom field mappings target real Salesforce field API names and are validated on save
and execution. Unsupported types and duplicate destinations are rejected server-side.

API and temporary connection failures retain five retries. Invalid mappings and ambiguous
email matches are recorded without automatic retries. The list shows an error indicator when sending fails. Error class, affected user ID, and timestamps are
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

Existing user custom fields are listed under **Custom fields**. Choose **Other…** and type a
field name (1–256 characters, no leading or trailing spaces) for one that is not listed.
Text values are sent as is, array items are sent individually, and other values are sent as JSON text.

When Salesforce confirms a linked Lead was deleted (and not converted), sync matches
by email again and creates a replacement if no active match exists. Missing or
inaccessible records without confirmed deletion remain errors.

### Batch syncing

`Jobs::SyncSalesforceUserBatch` uses `Salesforce::ConfiguredUserBatchSync` for backfills
and scheduled refreshes. Execution shares writable-field metadata cached for two hours per
connection and Salesforce object. Explicit saves and **Refresh field list** replace that cache
with fresh metadata. Each batch queries records
in groups of 25 (following Salesforce query pagination), and sends separate create
and update requests to the sObject Collections endpoint with `allOrNone: false`.
Unchanged records require no write. Each successful result saves its stable record link.

Per-user creation locks are acquired in ID order and shared with individual sync jobs.
Ambiguous matches, missing links, and failed collection entries fall back to individual
jobs, preserving deleted-Lead recovery and the existing retry limit. Write timeouts, connection failures, server errors, and malformed collection responses
queue individual ID/email reconciliation for the affected write entries. Already completed
entries are not requeued. Lookup failures and rejected writes (including authentication,
permission, and rate-limit errors) retain batch-level retries. Group joins
and profile changes continue to use individual REST requests. This uses synchronous
sObject Collections, not the asynchronous Bulk API 2.0.

### Stored activity and custom user fields

Activity mappings include posts created and read, likes given/received, and first/last
seen dates. Posts created, posts read, and likes given also have 30-day variants.
Posts read uses daily UserVisit totals for today and the preceding 29 calendar days.
Likes given counts like activity on non-deleted regular topics and posts in the past
30 days, excluding private messages. First/last seen describe activity, not login events.

Configured UserField definitions are discovered when loading or refreshing the field list.
Mappings use stable user_field_ID identifiers so renaming a field preserves the mapping;
deleting a field makes it invalid on the next validation. Text and dropdown fields map to
text, confirmation fields to Salesforce booleans, and date fields to date/datetime destinations.
Multi-select values are joined with semicolons for Salesforce multipicklists and commas for
other text fields. Missing values do not clear Salesforce fields. False and zero are preserved.

Batch jobs load only selected UserStat columns and configured custom-field values for all users
together. Batch and single-user jobs use the same value conversion.

Bio and Website are optional text sources from UserProfile. Bio uses the stored raw text
(including Markdown), not rendered HTML. Blank profile values do not clear Salesforce fields.
Selected profile columns are loaded once per batch. The Discourse source picker supports
search by label and groups sources into User details, Activity, Custom fields, and Custom values.

Sync configurations can select multiple groups. Membership uses the union of those groups;
backfill and scheduled batches deduplicate users before paging. A user remains eligible until
they leave every selected group. Configurations retain group IDs, so renaming a group updates
its displayed name without changing the synchronization scope. The group picker loads matching
groups from a lightweight endpoint when searching. Its “Create a group” footer action opens a
small modal using the core group endpoint and selects the new group without leaving the
configuration page. Groups are invite-only, with group-owner visibility for both the group and
its member list.
Mentions, messages, and assignment levels are set to nobody. Membership requests and public
joining/leaving are disabled. Groups remain available if the sync setup is canceled;
membership is managed from Groups.

Configurations for a different Salesforce instance are excluded from events and scheduled
sending. The list asks the administrator to configure and save them again. Explicitly saving
for the new connection resets the schedule and queues backfill when enabled.

Group joins and profile changes always trigger sending for active configurations.
Backfill and the activity refresh schedule remain optional.
After a successful individual sync, a digest of mapped values and mapping settings lets
unchanged profile-change jobs return before contacting Salesforce. Scheduled and group-join
syncs still check Salesforce. Failed attempts never advance the digest, so retries remain valid.

The configuration editor is a single page: group/object selection, sending behavior, and field
mapping. Salesforce metadata loads on entry and when the target object changes. Save remains available while editing. FormKit validates required fields and Salesforce
mapping rules when submitted, showing inline errors and an error summary before saving.

New Lead configurations explicitly map static text `Unknown` to Salesforce `Company`,
preserving non-empty Salesforce values by default. Admins can edit the text or select any
compatible source, including a configured custom user field named Company. Contacts do not
receive this default mapping. Company values from Discourse are selected through the corresponding
configured custom user field.

### Provider boundaries

Configurations persist an explicit `provider` identity.
Only Salesforce configurations are handled by the current jobs. Authentication, object
requirements, field conversion, matching and API batching remain Salesforce-specific.

`UserSyncSources` loads Discourse values independently of destination field names and
formats. It batches profile, statistics, custom field, group membership and recent post
queries. Salesforce serialization lives in `FieldMapping`,
which belongs to sync execution rather than the source loader.

`RecordLink` rows scope a remote ID by provider, account, object and Discourse user, with a
unique index on that tuple and an index on the remote ID for reverse lookups. Salesforce
currently uses its instance URL as the account identity. Configurations, their group scopes
and per-user sync state (fingerprint and last error) live in the `crm_sync_configurations`,
`crm_sync_configuration_groups` and `crm_sync_states` tables, named generically so another
CRM provider can share them. User custom fields remain compatibility fields for legacy
Salesforce features, not the provider-independent link store.

Reconciliation updates configured Contact links after merges and replaces converted Lead
links with a conversion marker. Configured Lead syncs skip converted users instead of retrying
an impossible update or creating a replacement Lead. Contact links retain the converted Lead
ID as provenance. These boundaries prepare for another provider without defining a shared API
adapter prematurely.

`ConfigurationScheduler` owns event-triggered enqueueing, activation backfills and periodic
refresh scheduling. `SyncConfiguration` retains validation and persistence. Scheduling
continues to use the existing timestamps and locks, so extracting it does not reset due dates.

`FieldMapping` evaluates payloads, including ownership rules, writable fields, and type conversion.

Reconciliation reloads user custom fields under the same per-user lock as sync jobs, then
updates the legacy ID and configured link within one database transaction. A failed link
write rolls back the legacy update, and stale responses cannot overwrite a newer legacy ID.

Configuration endpoints return translated authentication, permission, request-limit,
temporary-connection or unexpected-response errors. Diagnostic logs include the operation,
category and HTTP status, excluding upstream bodies, credentials and request headers.
