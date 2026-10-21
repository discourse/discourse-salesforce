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

### Guided workflow presentation demo

Open `/admin/plugins/discourse-salesforce/guided-sync` with Salesforce and
Discourse Workflows enabled. Changes live in the isolated demo worktrees.

The first wizard saves one demo Salesforce connection for the site. Subsequent
wizards skip the connection step, including after a page reload. Production and
staging Discourse sites each configure their own connection.

**Sync users** opens a wizard for independent Lead and Contact configurations.
**Sync posts** maps a support category's topic title, first-post description, tags,
structured product version, and attachments to Cases. Public reply directions can
be configured independently. Form fields, categories, and previews are sample data;
the support form itself and Salesforce synchronization are not implemented.

Saving a configuration creates or updates its workflows and **publishes** them.
Each workflow contains two connected steps: User created (user configurations) or
Post created (Case configurations), followed by an HTTP request. These are example
triggers illustrating the execution layer, rather than complete implementations of
each selected sync behavior. HTTP requests use simulation mode and never contact
the placeholder destination. Configuration settings are included in the request
step so changes can be inspected in the generated definitions.

The native Workflows list groups generated definitions under **Salesforce plugin**,
with a shared explanation that these workflows are read-only. The workflow detail
page also identifies its owner.
They are read-only there, including direct mutation API requests. **Edit plugin
configuration** opens the owning configuration using the `configuration` query
parameter. Direct links and page reloads retain the selected configuration;
Cancel clears the selection and returns to the list. Saving there updates
and republishes the same workflow IDs. Renaming a configuration updates its generated
workflow names while preserving IDs and execution history. **Duplicate to edit** creates an independent,
editable, unpublished copy. Copies are not owned by the configuration and are not
changed or deleted when the configuration changes.

**View executions** opens native execution history. Published example triggers can
produce execution records; simulated HTTP steps return request details without
sending requests. Execution inspection remains available for managed workflows.

**Delete configuration** lists and removes its related workflows and their execution
history after confirmation. Independently duplicated workflows and Salesforce
records are kept. Existing Workflows dependency checks apply; failures roll back
the whole deletion. Already-deleted workflows are skipped. Saving a configuration
also deletes workflows for disabled behaviors (including backfill), with the same
dependency checks and transaction rollback. Enabled workflows keep their IDs;
re-enabling a behavior creates a new workflow. Deletion removes execution history.

Mappings follow the supplied designs: aligned controls, arrows, source ownership,
searchable Salesforce fields, custom-field badges, inline reassignment errors, and
a sticky action bar. **Cancel** exits either wizard. The connected indicator is
aligned beside the workspace name; connection announcements remain available to
screen readers without a success banner.

The user wizard keeps the configuration form after saving. Generated workflows
are the only workflow list; the old concept tab, simulated run statistics, retry
warning, and simulated pause controls have been removed.

Wizard forms keep a stable FormKit `@data` object while updating the configuration
preview separately. Replacing `@data` during typing remounts the form and loses focus.
