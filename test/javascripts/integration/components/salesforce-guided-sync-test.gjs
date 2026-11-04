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
import { SALESFORCE_FIELDS } from "../../helpers/sync-fields-fixtures";

module("Integration | Component | SalesforceGuidedSync", function (hooks) {
  setupRenderingTest(hooks);
  hooks.beforeEach(function () {
    pretender.get("/salesforce/admin/guided-sync/groups.json", (request) => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({
        groups: this.groups.filter((group) =>
          group.name.includes(request.queryParams.q || "")
        ),
      }),
    ]);
    pretender.get("/salesforce/admin/guided-sync/fields.json", (request) => {
      this.requestedObject = request.queryParams.object;
      return [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
          custom_sources: this.customSources || [],
          fields: SALESFORCE_FIELDS.map((field) => ({
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
    this.groups = [
      { id: 1, name: "community-members", user_count: 248 },
      { id: 2, name: "customers", user_count: 86 },
      { id: 3, name: "partners", user_count: 32 },
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
      .hasText("Send users", "provides a default name");
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
      await click('[data-name="group_ids"] .d-multi-select-trigger');
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
      .dom('[data-name="group_ids"] .d-multi-select-trigger__selected-item')
      .exists({ count: 3 }, "preserves existing selections and adds the group");
    assert
      .dom('[data-name="group_ids"]')
      .includesText("new_customers", "selects the created group");
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
      await click('[data-name="group_ids"] .d-multi-select-trigger');
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
      .dom('[data-name="group_ids"] .d-multi-select-trigger__selected-item')
      .exists({ count: 1 }, "cancel does not change selected groups");
    assert
      .dom('[data-name="group_ids"]')
      .includesText("customers", "keeps the original group");
  });

  test("empty groups remain saveable", async function (assert) {
    this.groups = [{ id: 2, name: "customers", user_count: 0 }];
    const saved = [];
    this.save = (configuration) => saved.push(structuredClone(configuration));
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @onSave={{this.save}} />
      </template>
    );
    await selectSyncGroups("customers");
    await click("[data-test-save]");
    assert.deepEqual(
      saved.map((configuration) => configuration.group_ids),
      [[2]],
      "saves the selected empty group"
    );
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
      .dom('[data-name="group_ids"]')
      .includesText("customers", "retains edited values");
    await click("[data-test-configurations-back]");
    await click(".dialog-footer .btn-danger");
    assert.strictEqual(canceled, 1, "only discards after confirmation");
  });

  test("validates required groups and incomplete rows when Save is clicked", async function (assert) {
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
    assert
      .dom("[data-test-save]")
      .isEnabled("lets the administrator submit for validation");
    assert
      .dom(".form-kit__errors-summary")
      .doesNotExist("does not validate on entry");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .includesText("Discourse groups", "identifies the required group");
    assert.strictEqual(
      saved,
      undefined,
      "does not save an invalid configuration"
    );
    await selectSyncGroups("customers");
    await click("[data-test-add-mapping]");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .includesText("Salesforce field", "identifies the unfinished row");
    assert.strictEqual(saved, undefined, "does not save unfinished mappings");
    await click("[data-test-remove-mapping='7']");
    await click("[data-test-save]");
    assert.deepEqual(saved.group_ids, [2], "saves the valid configuration");
  });

  test("new mapping rows do not show errors until submitted", async function (assert) {
    this.record = { ...createSyncConfiguration(), group_ids: [2] };
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @record={{this.record}} />
      </template>
    );
    await click("[data-test-add-mapping]");
    assert.dom("[data-test-save]").isEnabled("keeps Save available");
    assert
      .dom(".form-kit__errors-summary")
      .doesNotExist("does not show an immediate error");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .exists("shows errors after submission");
  });

  test("required Salesforce mappings use the FormKit error summary", async function (assert) {
    this.record = { ...createSyncConfiguration(), group_ids: [2] };
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @record={{this.record}} />
      </template>
    );
    await click("[data-test-remove-mapping='6']");
    assert
      .dom(".form-kit__errors-summary")
      .doesNotExist("does not warn while editing");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .includesText("Map Company before saving.");
    await click("[data-test-remove-mapping='2']");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .includesText("Map LastName before saving.");
    assert
      .dom(".alert-error")
      .doesNotExist("does not duplicate the summary below mappings");
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
      .exists(
        { count: 4 },
        "groups user details, activity, custom fields and custom values"
      );
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
      .dom(".form-kit__control-menu-content .dropdown-menu")
      .includesText("No matching Discourse fields.", "shows an empty state");
  });

  test("mapping offers stored metrics and discovered custom fields with type validation", async function (assert) {
    pretender.get("/salesforce/admin/guided-sync/fields.json", () => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({
        fields: [
          ...SALESFORCE_FIELDS.map((field) => ({
            name: field.id,
            type: field.type === "number" ? "double" : "string",
          })),
          { name: "Posts_Read__c", type: "double" },
          { name: "Role__c", type: "string" },
        ],
        custom_sources: [
          { id: "user_field_42", name: "Job title", type: "text" },
        ],
      }),
    ]);
    const saved = [];
    this.save = (configuration) => saved.push(structuredClone(configuration));
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @onSave={{this.save}} />
      </template>
    );
    await selectSyncGroups("customers");
    await click("[data-test-add-mapping]");
    await formKit().field("mappings.4.source").select("posts_read30");
    await formKit().field("mappings.4.destination").select("Posts_Read__c");
    await click("[data-test-save]");
    assert.strictEqual(saved.length, 1, "saves a compatible numeric mapping");
    assert.propContains(saved[0].mappings[4], {
      source: "posts_read30",
      destination: "Posts_Read__c",
      policy: "overwrite",
    });
    await formKit().field("mappings.4.source").select("user_field_42");
    assert
      .dom('[data-name="mappings.4.source"]')
      .includesText("Job title", "labels configured fields");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .includesText("Job title (text) cannot map to Posts_Read__c (number)");
    assert.strictEqual(
      saved.length,
      1,
      "blocks an incompatible custom-field mapping"
    );
    await formKit().field("mappings.4.destination").select("Role__c");
    await click("[data-test-save]");
    assert.strictEqual(
      saved.length,
      2,
      "saves the repaired custom-field mapping"
    );
    assert.propContains(saved[1].mappings[4], {
      source: "user_field_42",
      destination: "Role__c",
      policy: "overwrite",
    });
  });

  test("saves static text with the selected ownership policy", async function (assert) {
    const saved = [];
    this.save = (configuration) => saved.push(structuredClone(configuration));
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @onSave={{this.save}} />
      </template>
    );
    await selectSyncGroups("customers");
    assert
      .dom('[data-name="mappings.4.source"]')
      .doesNotExist("does not add an extra mapping by default");
    await click("[data-test-add-mapping]");
    await formKit().field("mappings.4.source").select("static");
    await formKit().field("mappings.4.destination").select("LeadSource");
    await formKit().field("mappings.4.value").fillIn("");
    await click("[data-test-save]");
    assert.dom(".form-kit__errors-summary").exists("requires a static value");
    assert.strictEqual(saved.length, 0, "does not submit blank static text");
    await formKit().field("mappings.4.value").fillIn("Discourse");
    await formKit().field("mappings.4.policy").select("overwrite");
    assert
      .dom('[data-name="mappings.4.value"] input')
      .hasValue("Discourse", "retains static text after changing ownership");
    await click("[data-test-save]");
    assert.strictEqual(saved.length, 1);
    assert.propContains(saved[0].mappings[4], {
      source: "static",
      value: "Discourse",
      destination: "LeadSource",
      policy: "overwrite",
    });
  });

  test("Lead company defaults to editable static text and can use a custom field", async function (assert) {
    this.customSources = [
      { id: "user_field_42", name: "Company", type: "text" },
    ];
    const saved = [];
    this.save = (configuration) => saved.push(structuredClone(configuration));
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @onSave={{this.save}} />
      </template>
    );
    await selectSyncGroups("customers");
    assert
      .dom('[data-name="mappings.3.source"]')
      .includesText("Static text", "makes the default explicit");
    assert
      .dom('[data-name="mappings.3.value"] input')
      .hasValue("Unknown", "provides a fallback for new Leads");
    await formKit().field("mappings.3.value").fillIn("None");
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
    await click("[data-test-save]");
    assert.strictEqual(saved.length, 1, "submits the custom Company mapping");
    assert.propContains(saved[0].mappings[3], {
      source: "user_field_42",
      destination: "Company",
      policy: "keep",
    });
    await formKit().field("object").select("Contact");
    assert
      .dom('[data-name="mappings.3.source"]')
      .doesNotExist("Contacts do not require Company");
    await formKit().field("object").select("Lead");
    assert
      .dom('[data-name="mappings.3.value"] input')
      .hasValue("Unknown", "restores the explicit Lead default");
  });

  test("backfill label handles missing counts and uses the selected group's real count", async function (assert) {
    this.groups = [
      { id: 2, name: "customers", user_count: 86 },
      { id: 4, name: "empty", user_count: 0 },
      { id: 5, name: "unknown" },
    ];
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    assert.dom("[data-test-save]").hasText("Save and send");
    await click('[data-name="backfill"] input');
    assert.dom("[data-test-save]").hasText("Save configuration");
    await click('[data-name="backfill"] input');
    assert.dom("[data-test-save]").hasText("Save and send");
    await selectSyncGroups("unknown");
    assert
      .dom('[data-name="backfill"]')
      .includesText(
        "Send existing group members on activation",
        "does not interpolate a missing count"
      );
    await selectSyncGroups("customers");
    assert
      .dom('[data-name="backfill"]')
      .includesText(
        "Send 86 existing group members",
        "uses the selected group's count"
      );
    await selectSyncGroups("empty");
    assert
      .dom('[data-name="backfill"]')
      .includesText(
        "Send 0 existing group members",
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
    const saved = [];
    this.save = (configuration) => saved.push(structuredClone(configuration));
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @onSave={{this.save}} />
      </template>
    );
    await selectSyncGroups("customers");
    await formKit().field("object").select("Contact");
    await click("[data-test-save]");
    assert.strictEqual(saved.length, 1, "saves the standard Contact defaults");
    assert.strictEqual(saved[0].object, "Contact");
    assert.deepEqual(
      saved[0].mappings.map((mapping) => mapping.destination),
      ["FirstName", "LastName", "Description"]
    );
    this.record = {
      ...createSyncConfiguration(),
      id: "saved",
      group_ids: [2],
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
        <SalesforceGuidedSync
          @groups={{this.groups}}
          @record={{this.record}}
          @onSave={{this.save}}
        />
      </template>
    );
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .includesText(
        "Unavailable Salesforce fields: Company",
        "names missing saved destinations without removing them"
      );
    assert
      .dom(".form-kit__errors-summary")
      .includesText("Unavailable Salesforce fields: Posts_Created__c");
    assert.strictEqual(
      saved.length,
      1,
      "blocks saved mappings with unavailable destinations"
    );
    assert
      .dom('[data-name="mappings.3.destination"]')
      .includesText("Company", "retains the unavailable mapping for repair");
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
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .exists("prevents saving invalid data");
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
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .exists("prevents saving invalid data");
  });

  test("shows the server connection error when loading fields fails", async function (assert) {
    const message =
      "Salesforce denied access. Check the integration user’s object and field permissions, then retry.";
    pretender.get("/salesforce/admin/guided-sync/fields.json", () => [
      502,
      { "Content-Type": "application/json" },
      JSON.stringify({ errors: [message], error_type: "permissions" }),
    ]);
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    assert
      .dom(".salesforce-guided-sync")
      .includesText(message, "explains how to resolve the connection error");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .exists("prevents saving invalid data");
  });

  test("moving a destination requires repairing its previous mapping", async function (assert) {
    const saved = [];
    this.save = (configuration) => saved.push(structuredClone(configuration));
    await render(
      <template>
        <SalesforceGuidedSync @groups={{this.groups}} @onSave={{this.save}} />
      </template>
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
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .exists("prevents saving invalid data");

    await formKit().field("mappings.3.destination").select("Company");
    await formKit().field("mappings.2.destination").select("Description");
    await click("[data-test-save]");
    assert.strictEqual(
      saved.length,
      1,
      "submits after repairing both destinations"
    );
    assert.deepEqual(
      saved[0].mappings.map((mapping) => mapping.destination),
      ["FirstName", "LastName", "Description", "Company"]
    );

    await formKit().field("mappings.3.destination").select("Last_Seen__c");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .includesText("Static text (text) cannot map to Last_Seen__c (date)");
    await click("[data-test-save]");
    assert
      .dom(".form-kit__errors-summary")
      .exists("prevents saving invalid data");
  });
});
