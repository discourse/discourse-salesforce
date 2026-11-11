import { click, fillIn, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import DialogHolder from "discourse/dialog-holder/components/dialog-holder";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender from "discourse/tests/helpers/create-pretender";
import formKit from "discourse/tests/helpers/form-kit-helper";
import HubspotSyncConfiguration from "discourse/plugins/discourse-salesforce/discourse/components/hubspot-sync-configuration";
import { createHubspotSyncConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PROPERTIES = [
  { name: "lifecyclestage", label: "Lifecycle stage", type: "enumeration" },
  { name: "jobtitle", label: "Job title", type: "string" },
  { name: "city", label: "City", type: "string" },
];

async function selectProperty(name) {
  await click('[data-name="mappings"] .d-multi-select-trigger__expand-btn');
  await fillIn(".d-multi-select__search-input", name);
  await click(".d-multi-select__result");
  await click(".hubspot-sync-configuration__heading");
}

module("Integration | Component | HubspotSyncConfiguration", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    this.requests = [];
    pretender.get(
      "/salesforce/admin/hubspot/contact-properties.json",
      (request) => {
        this.requests.push(request.queryParams);
        return [
          200,
          { "Content-Type": "application/json" },
          JSON.stringify({ properties: PROPERTIES }),
        ];
      }
    );
  });

  test("loads contact properties, lets admins pick them and submits the selection", async function (assert) {
    this.saved = null;
    this.save = (configuration) => {
      this.saved = configuration;
      return true;
    };
    await render(
      <template><HubspotSyncConfiguration @onSave={{this.save}} /></template>
    );

    assert.deepEqual(
      this.requests,
      [{ refresh: "false" }],
      "requests HubSpot contact properties"
    );
    assert
      .dom("[data-test-user-pull-note]")
      .exists("notes that users are also matched individually");
    assert
      .dom('[data-name="mappings"] .d-multi-select-trigger__selected-item')
      .hasText("Lifecycle stage", "preselects the default property");

    await selectProperty("Job");
    await click("[data-test-refresh-properties]");
    assert.strictEqual(
      this.requests.at(-1).refresh,
      "true",
      "refresh bypasses the cache"
    );
    await formKit().field("backfill").toggle();
    await formKit().field("schedule").select("weekly");
    await click("[data-test-save]");

    assert.deepEqual(
      this.saved,
      {
        ...createHubspotSyncConfiguration(),
        backfill: false,
        schedule: "weekly",
        mappings: [
          { id: 1, source: "lifecyclestage" },
          { id: 2, source: "jobtitle" },
        ],
      },
      "submits the provider, direction, kind, object, schedule and properties"
    );
  });

  test("keeps the saved selection, including properties HubSpot no longer reports", async function (assert) {
    this.record = {
      ...createHubspotSyncConfiguration(),
      id: 7,
      name: "Customer stages",
      mappings: [
        { id: 1, source: "jobtitle" },
        { id: 2, source: "removed_property" },
      ],
    };
    this.save = () => true;
    await render(
      <template>
        <HubspotSyncConfiguration
          @record={{this.record}}
          @onSave={{this.save}}
        />
      </template>
    );

    assert.dom(".d-page-subheader__title").hasText("Customer stages");
    assert
      .dom('[data-name="mappings"] .d-multi-select-trigger__selected-item')
      .exists({ count: 2 }, "shows every saved property");
    await click("[data-test-save]");
    assert
      .dom('[data-name="mappings"] .form-kit__errors')
      .includesText(
        "removed_property",
        "refuses to save unavailable properties"
      );
  });

  test("explains property loading failures and retries", async function (assert) {
    let failures = 1;
    pretender.get("/salesforce/admin/hubspot/contact-properties.json", () => {
      if (failures-- > 0) {
        return [
          502,
          { "Content-Type": "application/json" },
          JSON.stringify({ errors: ["HubSpot authentication failed."] }),
        ];
      }
      return [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({ properties: PROPERTIES }),
      ];
    });
    await render(
      <template><HubspotSyncConfiguration /><DialogHolder /></template>
    );

    assert
      .dom(".hubspot-sync-configuration .form-kit__alert")
      .includesText("HubSpot authentication failed.", "shows the server error");
    await click("[data-test-refresh-properties]");
    assert
      .dom('[data-name="mappings"]')
      .exists("shows the picker once properties load");
  });
});
