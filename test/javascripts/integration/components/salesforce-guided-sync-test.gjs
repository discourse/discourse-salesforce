import {
  click,
  fillIn as fillInput,
  find,
  render,
  triggerKeyEvent,
} from "@ember/test-helpers";
import { module, test } from "qunit";
import ModalContainer from "discourse/components/modal-container";
import DialogHolder from "discourse/dialog-holder/components/dialog-holder";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender from "discourse/tests/helpers/create-pretender";
import formKit from "discourse/tests/helpers/form-kit-helper";
import SalesforceGuidedSync from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-guided-sync";
import { createSyncConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";
import selectSyncGroups from "../../helpers/select-sync-groups";
import { buildPreview, DEMO_FIELDS } from "../../helpers/sync-preview-fixtures";

module("Integration | Component | SalesforceGuidedSync", function (hooks) {
  setupRenderingTest(hooks);
  hooks.beforeEach(function () {
    pretender.get("/salesforce/admin/guided-sync/configurations.json", () => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({ groups: this.groups }),
    ]);
    pretender.get("/salesforce/admin/guided-sync/fields.json", (request) => {
      this.requestedObject = request.queryParams.object;
      return [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
          custom_sources: this.customSources || [],
          fields: DEMO_FIELDS.map((field) => ({
            name: field.id,
            type:
              field.type === "number"
                ? "double"
                : field.type === "date"
                  ? "date"
                  : "string",
          })),
        }),
      ];
    });
    pretender.get("/salesforce/admin/guided-sync/preview-users.json", () => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({
        users: [
          { id: 1, username: "alex", name: "Alex Morgan" },
          { id: 2, username: "maya", name: "Maya Chen" },
        ],
      }),
    ]);
    pretender.post("/salesforce/admin/guided-sync/preview.json", (request) => {
      const body = JSON.parse(request.requestBody);
      this.previewRequest = body;
      return [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
          user:
            Number(body.user_id) === 2
              ? { id: 2, username: "maya" }
              : { id: 1, username: "alex" },
          rows: buildPreview(
            body.configuration,
            Number(body.user_id) === 2 ? "maya" : "alex"
          ),
        }),
      ];
    });
    this.groups = [
      { name: "community-members", user_count: 248 },
      { name: "customers", user_count: 86 },
      { name: "partners", user_count: 32 },
    ];
  });

  test("configuration naming is optional and edited from the heading", async function (assert) {
    this.save = () => {};
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @onSave={{this.save}} />
      </template>
    );

    assert
      .dom(".d-page-subheader__title")
      .hasText("User sync", "provides a default name");
    assert
      .dom('[data-name="name"]')
      .doesNotExist("keeps naming out of Choose users");

    await click("[data-test-edit-name]");
    assert
      .dom(
        ".salesforce-guided-sync__heading .salesforce-guided-sync__name-form"
      )
      .exists("edits the name in the heading");
    assert
      .dom(".d-page-subheader__title")
      .doesNotExist("replaces the title while editing");
    await fillInput(
      ".salesforce-guided-sync__name-form input",
      "Customer contacts"
    );
    await click('.salesforce-guided-sync__name-form button[type="submit"]');
    assert
      .dom(".d-page-subheader__title")
      .hasText("Customer contacts", "applies the name");
    assert
      .dom(".salesforce-guided-sync__name-form")
      .doesNotExist("closes the editor");

    await click("[data-test-edit-name]");
    await fillInput(
      ".salesforce-guided-sync__name-form input",
      "Discarded name"
    );
    await click(".salesforce-guided-sync__name-actions .btn-transparent");
    assert
      .dom(".d-page-subheader__title")
      .hasText("Customer contacts", "cancel preserves the name");
    await click("[data-test-edit-name]");
    await fillInput(
      ".salesforce-guided-sync__name-form input",
      "Discard with Escape"
    );
    await triggerKeyEvent(
      ".salesforce-guided-sync__name-form input",
      "keydown",
      "Escape"
    );
    assert
      .dom(".d-page-subheader__title")
      .hasText("Customer contacts", "Escape discards the inline edit");
  });

  test("creates a group in a modal and adds it to the selected groups", async function (assert) {
    pretender.post("/admin/groups", (request) => {
      assert.strictEqual(
        new URLSearchParams(request.requestBody).get("group[name]"),
        "new_customers",
        "submits the group name to core"
      );
      const params = new URLSearchParams(request.requestBody);
      assert.deepEqual(
        Object.fromEntries(
          [...params].filter(([key]) => key !== "group[name]")
        ),
        {
          "group[visibility_level]": "4",
          "group[members_visibility_level]": "4",
          "group[public_admission]": "false",
          "group[public_exit]": "false",
          "group[allow_membership_requests]": "false",
          "group[mentionable_level]": "0",
          "group[messageable_level]": "0",
          "group[assignable_level]": "0",
        },
        "creates an invite-only group with owner visibility and no posting or assignment access"
      );
      return [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({ basic_group: { id: 1234, name: "new_customers" } }),
      ];
    });
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} /><ModalContainer />
      </template>
    );
    await selectSyncGroups("customers", "partners");
    if (!find("[data-test-create-group]")) {
      await click('[data-name="groups"] .d-multi-select-trigger');
    }
    await click("[data-test-create-group]");
    await fillInput(
      '.salesforce-create-group-modal [data-name="name"] input',
      "new_customers"
    );
    await click('.salesforce-create-group-modal button[type="submit"]');
    assert
      .dom(".salesforce-create-group-modal")
      .doesNotExist("closes after creation");
    assert
      .dom('[data-name="groups"] .d-multi-select-trigger__selected-item')
      .exists({ count: 3 }, "preserves existing selections and adds the group");
    assert
      .dom('[data-name="groups"]')
      .includesText("new_customers", "selects the created group");
    assert
      .dom("[data-test-save]")
      .isEnabled("keeps the configuration ready to save");
  });

  test("group creation errors keep the modal open and cancel preserves the selection", async function (assert) {
    pretender.post("/admin/groups", () => [
      422,
      { "Content-Type": "application/json" },
      JSON.stringify({ errors: ["Name has already been taken"] }),
    ]);
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} /><ModalContainer />
      </template>
    );
    await selectSyncGroups("customers");
    if (!find("[data-test-create-group]")) {
      await click('[data-name="groups"] .d-multi-select-trigger');
    }
    await click("[data-test-create-group]");
    await fillInput(
      '.salesforce-create-group-modal [data-name="name"] input',
      "customers"
    );
    await click('.salesforce-create-group-modal button[type="submit"]');
    assert
      .dom(".salesforce-create-group-modal .alert-error")
      .includesText(
        "Name has already been taken",
        "shows the core validation error"
      );
    await click(".salesforce-create-group-modal .btn-transparent");
    assert
      .dom('[data-name="groups"] .d-multi-select-trigger__selected-item')
      .exists({ count: 1 }, "cancel does not change selected groups");
    assert
      .dom('[data-name="groups"]')
      .includesText("customers", "keeps the original group");
  });

  test("empty groups show sample data and remain saveable without a user selector", async function (assert) {
    pretender.post("/salesforce/admin/guided-sync/preview.json", () => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({
        user: null,
        sample: true,
        rows: [
          {
            field: "LastName",
            current: "Taylor",
            incoming: "Morgan",
            result: "Taylor",
            outcome: "kept",
          },
        ],
      }),
    ]);
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");
    assert
      .dom("[data-test-sample-preview]")
      .includesText("Sample user", "labels the sample fallback");
    assert
      .dom('[data-name="previewMember"]')
      .doesNotExist("does not offer a nonexistent user");
    assert
      .dom('[data-test-preview-field="LastName"]')
      .includesText("Taylor", "renders the sample mapping outcome");
    assert
      .dom("[data-test-save]")
      .isEnabled("allows saving an empty group's configuration");

    pretender.post("/salesforce/admin/guided-sync/preview.json", () => [
      503,
      { "Content-Type": "application/json" },
      JSON.stringify({ errors: ["Preview unavailable"] }),
    ]);
    await click("[data-test-refresh-fields]");
    assert
      .dom("[data-test-sample-preview]")
      .doesNotExist("does not mask errors as sample data");
    assert
      .dom("[data-test-retry-preview]")
      .exists("offers a retry after failure");
  });

  test("Cancel confirms before discarding configuration changes", async function (assert) {
    let canceled = 0;
    this.cancel = () => canceled++;
    await render(
      <template>
        <SalesforceGuidedSync
          @groups={{this.groups}}
          @onCancel={{this.cancel}}
        /><DialogHolder />
      </template>
    );
    await selectSyncGroups("customers");
    await click("[data-test-configurations-back]");
    assert.strictEqual(canceled, 0, "does not cancel immediately");
    assert
      .dom(".dialog-body")
      .includesText(
        "Your unsaved configuration changes will be lost.",
        "explains what will be discarded"
      );
    await click(".dialog-footer .btn-default");
    assert.strictEqual(canceled, 0, "Keep editing preserves the configuration");
    assert
      .dom('[data-name="groups"]')
      .includesText("customers", "retains edited values");
    await click("[data-test-configurations-back]");
    await click(".dialog-footer .btn-danger");
    assert.strictEqual(canceled, 1, "only discards after confirmation");
  });

  test("shows the entire configuration and saves only valid mappings", async function (assert) {
    let saved;
    this.save = (configuration) => {
      saved = configuration;
      return true;
    };
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @onSave={{this.save}} />
      </template>
    );
    assert.dom("[data-test-step]").doesNotExist("has no wizard navigation");
    assert
      .dom(".salesforce-guided-sync__section")
      .exists(
        { count: 4 },
        "shows scope, behavior, mappings and preview together"
      );
    assert.dom("[data-test-save]").isDisabled("requires a group");
    assert
      .dom(
        ".salesforce-guided-sync__mapping-headings [data-name='previewMember']"
      )
      .doesNotExist("keeps the mapping table focused on field controls");
    await selectSyncGroups("customers");
    await formKit().field("schedule").select("weekly");
    await click("[data-test-add-mapping]");
    assert
      .dom("[data-test-save]")
      .isDisabled("unfinished mappings block saving");
    await click("[data-test-remove-mapping='7']");
    await click("[data-test-save]");
    assert.deepEqual(saved.groups, ["customers"], "saves selected groups");
    assert.strictEqual(
      saved.schedule,
      "weekly",
      "saves behavior with mappings"
    );
  });

  test("review switches members, searches the group, and supports empty and failed previews", async function (assert) {
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");
    await formKit().field("object").select("Contact");
    assert
      .dom('[data-name="previewMember"]')
      .includesText("alex", "selects the first member");
    assert
      .dom("[data-test-preview-section] [data-name='previewMember']")
      .exists("places user selection in the separate preview section");

    let searchedGroup;
    pretender.get(
      "/salesforce/admin/guided-sync/preview-users.json",
      (request) => {
        searchedGroup = request.queryParams;
        return [
          200,
          { "Content-Type": "application/json" },
          JSON.stringify({ users: [{ id: 2, username: "maya" }] }),
        ];
      }
    );
    await click('[data-name="previewMember"] .form-kit__control-menu-trigger');
    await fillInput(".dropdown-menu .filter-input", "maya");
    assert.strictEqual(
      searchedGroup["groups[]"],
      "customers",
      "search stays scoped to the group"
    );
    assert.strictEqual(
      searchedGroup.q,
      "maya",
      "search sends the entered query"
    );
    await click('.form-kit__control-menu-item[data-value="2"] button');
    assert.strictEqual(
      this.previewRequest.user_id,
      2,
      "requests the selected member"
    );
    assert
      .dom('[data-test-preview-field="LastName"]')
      .includesText("Chen", "refreshes values for the selected member");

    pretender.post("/salesforce/admin/guided-sync/preview.json", () => [
      503,
      { "Content-Type": "application/json" },
      JSON.stringify({ errors: ["Preview unavailable"] }),
    ]);
    await click("[data-test-refresh-fields]");
    assert
      .dom(".alert-error")
      .includesText("Preview unavailable", "shows failure");
    assert
      .dom('[data-test-preview-field="LastName"]')
      .doesNotExist("clears stale values on failure");
    pretender.post("/salesforce/admin/guided-sync/preview.json", () => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({ user: null, rows: [] }),
    ]);
    await click("[data-test-retry-preview]");
    assert
      .dom('[data-test-preview-field="LastName"]')
      .doesNotExist("shows no preview rows instead of sample data");
  });

  test("source picker filters grouped fields and highlights the selected source", async function (assert) {
    this.customSources = [
      { id: "user_field_42", name: "Job title", type: "text" },
    ];
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");
    await click(
      '[data-name="mappings.0.source"] .form-kit__control-menu-trigger'
    );
    assert
      .dom(".salesforce-source-menu__group")
      .exists({ count: 3 }, "groups user details, activity and custom fields");
    assert
      .dom('.form-kit__control-menu-item[data-value="first"] .--selected')
      .exists("highlights the current source");
    await fillInput(".salesforce-source-menu__search input", "website");
    assert
      .dom(".salesforce-source-menu__option")
      .exists({ count: 1 }, "filters by display name");
    await click('.form-kit__control-menu-item[data-value="website"] button');
    assert
      .dom('[data-name="mappings.0.source"]')
      .includesText("Website", "selects the profile website");
    await click(
      '[data-name="mappings.0.source"] .form-kit__control-menu-trigger'
    );
    await fillInput(".salesforce-source-menu__search input", "bio");
    await click('.form-kit__control-menu-item[data-value="bio"] button');
    assert
      .dom('[data-name="mappings.0.source"]')
      .includesText("Bio", "offers the profile bio");
    await click(
      '[data-name="mappings.0.source"] .form-kit__control-menu-trigger'
    );
    await fillInput(".salesforce-source-menu__search input", "job");
    assert
      .dom(".salesforce-source-menu__option")
      .includesText("Job title", "searches configured custom field labels");
    await fillInput(".salesforce-source-menu__search input", "no-such-field");
    assert
      .dom(".salesforce-source-menu__option")
      .doesNotExist("clears non-matching options");
    assert
      .dom(".dropdown-menu")
      .includesText("No matching Discourse fields.", "shows an empty state");
  });

  test("mapping offers stored metrics and discovered custom fields with type validation", async function (assert) {
    pretender.get("/salesforce/admin/guided-sync/fields.json", () => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({
        fields: [
          ...DEMO_FIELDS.map((field) => ({
            name: field.id,
            type: field.type === "number" ? "double" : "string",
          })),
          { name: "Read_Minutes__c", type: "double" },
          { name: "Role__c", type: "string" },
        ],
        custom_sources: [
          { id: "user_field_42", name: "Job title", type: "text" },
        ],
      }),
    ]);
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");
    await click("[data-test-add-mapping]");
    await formKit().field("mappings.4.source").select("read_time");
    await formKit().field("mappings.4.destination").select("Read_Minutes__c");
    assert
      .dom("[data-test-save]")
      .isEnabled("accepts numeric activity metrics");
    await formKit().field("mappings.4.source").select("user_field_42");
    assert
      .dom('[data-name="mappings.4.source"]')
      .includesText("Job title", "labels configured fields");
    assert
      .dom("[data-test-save]")
      .isDisabled("rejects incompatible custom field types");
    await formKit().field("mappings.4.destination").select("Role__c");
    assert.dom("[data-test-save]").isEnabled("accepts text custom fields");
  });

  test("static text can be entered and previewed with ownership rules", async function (assert) {
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");
    assert
      .dom('[data-name="mappings.4.source"]')
      .doesNotExist("does not add static text by default");
    await click("[data-test-add-mapping]");
    await formKit().field("mappings.4.source").select("static");
    await formKit().field("mappings.4.destination").select("LeadSource");
    await formKit().field("mappings.4.value").fillIn("");
    assert.dom("[data-test-save]").isDisabled("requires a static value");
    await formKit().field("mappings.4.value").fillIn("Discourse");
    await formKit().field("mappings.4.policy").select("overwrite");
    assert
      .dom('[data-test-preview-field="LeadSource"]')
      .includesText("Discourse", "previews the entered value");
    assert
      .dom('[data-name="mappings.4.value"] input')
      .hasValue("Discourse", "retains the text when returning to mappings");
  });

  test("Lead company defaults to editable static text and can use a custom field", async function (assert) {
    this.customSources = [
      { id: "user_field_42", name: "Company", type: "text" },
    ];
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");
    assert
      .dom('[data-name="mappings.3.source"]')
      .includesText("Static text", "makes the default explicit");
    assert
      .dom('[data-name="mappings.3.value"] input')
      .hasValue("Unknown", "uses the PM default");
    await formKit().field("mappings.3.value").fillIn("None");
    assert
      .dom('[data-test-preview-field="Company"]')
      .includesText("None", "previews the edited static value");
    await click(
      '[data-name="mappings.3.source"] .form-kit__control-menu-trigger'
    );
    assert
      .dom('.form-kit__control-menu-item[data-value="company"]')
      .doesNotExist("does not offer an invented built-in Company field");
    await click(
      '.form-kit__control-menu-item[data-value="user_field_42"] button'
    );
    assert
      .dom('[data-name="mappings.3.source"]')
      .includesText("Company", "supports the discovered custom field");
    assert
      .dom('[data-name="mappings.3.value"]')
      .doesNotExist("hides static text when remapped");
    assert
      .dom("[data-test-save]")
      .isEnabled("accepts the custom field mapping");
    await formKit().field("object").select("Contact");
    assert
      .dom('[data-name="mappings.3.source"]')
      .doesNotExist("Contacts do not require Company");
    await formKit().field("object").select("Lead");
    assert
      .dom('[data-name="mappings.3.value"] input')
      .hasValue("Unknown", "restores the explicit Lead default");
  });

  test("legacy fixed values open as editable static text", async function (assert) {
    this.record = createSyncConfiguration();
    this.record.mappings[4] = {
      id: 7,
      source: "source",
      destination: "LeadSource",
      policy: "keep",
    };
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @record={{this.record}} />
      </template>
    );
    await selectSyncGroups("customers");
    assert
      .dom('[data-name="mappings.4.value"] input')
      .hasValue("Community", "preserves the legacy value");
    assert
      .dom('[data-name="mappings.4.source"] option[value="source"]')
      .doesNotExist("removes the redundant fixed-value option");
    await formKit().field("mappings.4.value").fillIn("Discourse");
    assert
      .dom('[data-name="mappings.4.value"] input')
      .hasValue("Discourse", "allows editing the old fixed value");
  });

  test("backfill label handles missing counts and uses the selected group's real count", async function (assert) {
    this.groups = [
      { name: "customers", user_count: 86 },
      { name: "empty", user_count: 0 },
      { name: "unknown" },
    ];
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("unknown");
    assert
      .dom('[data-name="backfill"]')
      .includesText(
        "Sync existing group members on activation",
        "does not interpolate a missing count"
      );
    await selectSyncGroups("customers");
    assert
      .dom('[data-name="backfill"]')
      .includesText(
        "Sync 86 existing group members",
        "uses the selected group's count"
      );
    await selectSyncGroups("empty");
    assert
      .dom('[data-name="backfill"]')
      .includesText(
        "Sync 0 existing group members",
        "preserves a real zero count"
      );
  });

  test("new Contact mappings use standard fields and saved mappings identify unavailable fields", async function (assert) {
    pretender.get("/salesforce/admin/guided-sync/fields.json", () => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({
        fields: ["FirstName", "LastName", "Description", "LeadSource"].map(
          (name) => ({ name, type: "string" })
        ),
      }),
    ]);
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");
    await formKit().field("object").select("Contact");
    assert
      .dom("[data-test-save]")
      .isEnabled("new Contact defaults do not assume custom or Company fields");
    this.record = {
      ...createSyncConfiguration(),
      id: "saved",
      group: "customers",
      object: "Contact",
    };
    this.record.mappings.push({
      id: 8,
      source: "posts",
      destination: "Posts_Created__c",
      policy: "overwrite",
    });
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @record={{this.record}} />
      </template>
    );
    assert
      .dom(".salesforce-guided-sync")
      .includesText(
        "Unavailable Salesforce fields: Company, Posts_Created__c",
        "names missing saved destinations without removing them"
      );
    assert
      .dom("[data-test-save]")
      .isDisabled("saved unavailable mappings must be repaired");
  });

  test("reloads metadata when the target changes and allows retrying failures", async function (assert) {
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");
    assert.strictEqual(this.requestedObject, "Lead");
    pretender.get("/salesforce/admin/guided-sync/fields.json", () => [
      502,
      {},
      "",
    ]);
    await formKit().field("object").select("Contact");
    assert
      .dom(".salesforce-guided-sync")
      .includesText("Could not load Salesforce fields");
    assert.dom("[data-test-save]").isDisabled();
    pretender.get("/salesforce/admin/guided-sync/fields.json", (request) => {
      this.requestedObject = request.queryParams.object;
      return [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
          fields: [{ name: "Contact_Only__c", type: "string" }],
        }),
      ];
    });
    await click("[data-test-refresh-fields]");
    assert.strictEqual(this.requestedObject, "Contact");
    assert
      .dom(".salesforce-guided-sync")
      .doesNotIncludeText("Could not load Salesforce fields");
    assert
      .dom("[data-test-save]")
      .isDisabled("missing mapped fields must be repaired");
  });

  test("moving a destination requires repairing its previous mapping", async function (assert) {
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await selectSyncGroups("customers");

    await formKit().field("mappings.3.destination").select("Description");
    assert
      .dom(
        '[data-name="mappings.2.destination"] .form-kit__control-menu-trigger'
      )
      .includesText("Choose a field", "clears the previous destination");
    assert
      .dom('[data-test-mapping="3"]')
      .includesText("This destination moved");
    assert.dom("[data-test-save]").isDisabled();

    await formKit().field("mappings.3.destination").select("Company");
    await formKit().field("mappings.2.destination").select("Description");
    assert.dom("[data-test-save]").isEnabled();

    await formKit().field("mappings.3.destination").select("Last_Seen__c");
    assert
      .dom(".alert-error")
      .includesText(
        "Company (profile field, or None if empty) (text) cannot map to Last_Seen__c (date)"
      );
    assert.dom("[data-test-save]").isDisabled();
  });
});
