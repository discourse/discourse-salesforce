import { click, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender from "discourse/tests/helpers/create-pretender";
import formKit from "discourse/tests/helpers/form-kit-helper";
import SalesforceGuidedSync from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-guided-sync";
import {
  createDemoConfiguration,
  DEMO_FIELDS,
} from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-demo";

module("Integration | Component | SalesforceGuidedSync", function (hooks) {
  setupRenderingTest(hooks);
  hooks.beforeEach(function () {
    pretender.get("/salesforce/admin/guided-sync/fields.json", (request) => {
      this.requestedObject = request.queryParams.object;
      return [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
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
    this.groups = [
      { name: "community-members", user_count: 248 },
      { name: "customers", user_count: 86 },
      { name: "partners", user_count: 32 },
    ];
  });

  test("static text can be entered and previewed with ownership rules", async function (assert) {
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await formKit().field("group").select("customers");
    await click('[data-test-step="mapping"]');
    await formKit().field("mappings.4.source").select("static");
    await formKit().field("mappings.4.value").fillIn("");
    assert.dom("[data-test-continue]").isDisabled("requires a static value");
    await formKit().field("mappings.4.value").fillIn("Discourse");
    await formKit().field("mappings.4.policy").select("overwrite");
    await click('[data-test-step="review"]');
    assert
      .dom('[data-test-preview-field="LeadSource"]')
      .includesText("Discourse", "previews the entered value");
    await click('[data-test-step="mapping"]');
    assert
      .dom('[data-name="mappings.4.value"] input')
      .hasValue("Discourse", "retains the text when returning to mappings");
  });

  test("legacy fixed values open as editable static text", async function (assert) {
    this.record = createDemoConfiguration();
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
    await click('[data-test-step="mapping"]');
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
    ];
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await click('[data-test-step="behavior"]');
    assert
      .dom('[data-name="backfill"]')
      .includesText(
        "Sync existing group members on activation",
        "does not interpolate a missing count"
      );
    await click('[data-test-step="scope"]');
    await formKit().field("group").select("customers");
    await click('[data-test-step="behavior"]');
    assert
      .dom('[data-name="backfill"]')
      .includesText(
        "Sync 86 existing group members",
        "uses the selected group's count"
      );
    await click('[data-test-step="scope"]');
    await formKit().field("group").select("empty");
    await click('[data-test-step="behavior"]');
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
    await formKit().field("group").select("customers");
    await formKit().field("object").select("Contact");
    await click("[data-test-continue]");
    assert
      .dom("[data-test-continue]")
      .isEnabled("new Contact defaults do not assume custom or Company fields");
    this.record = {
      ...createDemoConfiguration(),
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
    await click("[data-test-continue]");
    assert
      .dom(".salesforce-guided-sync")
      .includesText(
        "Unavailable Salesforce fields: Company, Posts_Created__c",
        "names missing saved destinations without removing them"
      );
    assert
      .dom("[data-test-continue]")
      .isDisabled("saved unavailable mappings must be repaired");
  });

  test("reloads metadata when the target changes and allows retrying failures", async function (assert) {
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await formKit().field("group").select("customers");
    await click("[data-test-continue]");
    assert.strictEqual(this.requestedObject, "Lead");
    await click('[data-test-step="scope"]');
    await formKit().field("object").select("Contact");
    pretender.get("/salesforce/admin/guided-sync/fields.json", () => [
      502,
      {},
      "",
    ]);
    await click("[data-test-continue]");
    assert
      .dom(".salesforce-guided-sync")
      .includesText("Could not load Salesforce fields");
    assert.dom("[data-test-continue]").isDisabled();
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
      .dom("[data-test-continue]")
      .isDisabled("missing mapped fields must be repaired");
  });

  test("guided setup previews ownership rules and enables a simulated sync", async function (assert) {
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );

    assert.dom('[data-test-step="connect"]').doesNotExist();
    assert.dom("[data-test-step]").exists({ count: 4 }, "shows four steps");
    assert.dom(".salesforce-guided-sync__footer").includesText("Step 1 of 4");
    assert
      .dom("[data-test-continue]")
      .isDisabled("requires a real group selection");
    await formKit().field("group").select("customers");
    await formKit().field("object").select("Contact");
    await click("[data-test-continue]");
    assert.strictEqual(
      this.requestedObject,
      "Contact",
      "requests Contact metadata"
    );

    assert
      .dom(
        '[data-name="mappings.3.destination"] .form-kit__control-menu-trigger'
      )
      .includesText("LeadSource", "shows the returned API field name");
    await click("[data-test-continue]");
    await formKit().field("schedule").select("weekly");
    await click("[data-test-continue]");

    assert
      .dom('[data-test-preview-field="FirstName"]')
      .includesText("Alexander");
    assert
      .dom('[data-test-preview-field="FirstName"]')
      .includesText("Kept Salesforce");

    assert
      .dom('[data-name="previewUser"]')
      .doesNotExist("uses one fixed confirmation example");

    await click("[data-test-continue]");
    assert.dom(".salesforce-guided-sync__stats").doesNotExist();
    assert.dom("[data-test-retry-failure]").doesNotExist();
    await click('[data-test-step="mapping"]');
    await formKit().field("mappings.3.policy").select("keep");
    await click('[data-test-step="review"]');
    await click("[data-test-continue]");
    assert
      .dom("[data-test-demo-message]")
      .includesText("Demo configuration saved");
    assert.dom("[data-test-retry-failure]").doesNotExist();
  });

  test("moving a destination requires repairing its previous mapping", async function (assert) {
    await render(
      <template><SalesforceGuidedSync @groups={{this.groups}} /></template>
    );
    await formKit().field("group").select("customers");
    await click('[data-test-step="mapping"]');

    await formKit().field("mappings.3.destination").select("Description");
    assert
      .dom(
        '[data-name="mappings.2.destination"] .form-kit__control-menu-trigger'
      )
      .includesText("Choose a field", "clears the previous destination");
    assert
      .dom('[data-test-mapping="3"]')
      .includesText("This destination moved");
    assert.dom("[data-test-continue]").isDisabled();

    await formKit().field("mappings.3.destination").select("Company");
    await formKit().field("mappings.2.destination").select("Description");
    assert.dom("[data-test-continue]").isEnabled();

    await formKit().field("mappings.3.destination").select("Last_Seen__c");
    assert
      .dom(".alert-error")
      .includesText(
        "Company (profile field, or None if empty) (text) cannot map to Last_Seen__c (date)"
      );
    assert.dom("[data-test-continue]").isDisabled();
  });
});
