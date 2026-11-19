import { click, fillIn, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import DialogHolder from "discourse/dialog-holder/components/dialog-holder";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender from "discourse/tests/helpers/create-pretender";
import formKit from "discourse/tests/helpers/form-kit-helper";
import HubspotSyncConfiguration from "discourse/plugins/discourse-salesforce/discourse/components/hubspot-sync-configuration";
import { createHubspotSyncConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PROPERTIES = {
  contact: [
    { name: "lifecyclestage", label: "Lifecycle stage", type: "enumeration" },
    { name: "jobtitle", label: "Job title", type: "string" },
    { name: "city", label: "City", type: "string" },
  ],
  company: [
    { name: "name", label: "Name", type: "string" },
    { name: "plan_tier", label: "Plan tier", type: "string" },
  ],
};

function propertiesResponse(object) {
  return [
    200,
    { "Content-Type": "application/json" },
    JSON.stringify({ properties: PROPERTIES[object] }),
  ];
}

async function selectProperty(object, name) {
  await click(
    `[data-name="${object}_properties"] .d-multi-select-trigger__expand-btn`
  );
  await fillIn(".d-multi-select__search-input", name);
  await click(".d-multi-select__result");
  await click(".hubspot-sync-configuration__heading");
}

module("Integration | Component | HubspotSyncConfiguration", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    this.requests = [];
    pretender.get("/salesforce/admin/hubspot/properties.json", (request) => {
      this.requests.push(request.queryParams);
      return propertiesResponse(request.queryParams.object);
    });
  });

  test("loads contact properties, pulls companies on request and submits the selection", async function (assert) {
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
      [{ object: "contact", refresh: "false" }],
      "requests only the contact properties until companies are pulled"
    );
    assert
      .dom('[data-name="object"] .form-kit__control-menu-trigger')
      .hasText("HubSpot - Contacts", "pulls HubSpot contacts");
    await click('[data-name="object"] .form-kit__control-menu-trigger');
    assert
      .dom("[data-test-coming-soon-object]")
      .exists({ count: 2 }, "lists the objects that cannot be pulled yet");
    assert
      .dom('[data-test-coming-soon-object="Lead"]')
      .hasText("Salesforce - Leads (coming soon)")
      .isDisabled("marks them as coming soon");
    await click('.form-kit__control-menu-item[data-value="contact"] .btn');
    assert
      .dom("[data-test-user-pull-note]")
      .exists("notes that users are also matched individually");
    assert
      .dom(
        '[data-name="contact_properties"] .d-multi-select-trigger__selected-item'
      )
      .hasText("Lifecycle stage", "preselects the default contact property");
    assert
      .form()
      .field("pull_companies")
      .hasValue(false, "starts without companies");
    assert
      .dom('[data-name="company_properties"]')
      .doesNotExist("hides the company picker until companies are pulled");

    await selectProperty("contact", "Job");
    await formKit().field("pull_companies").toggle();
    assert.deepEqual(
      this.requests.at(-1),
      { object: "company", refresh: "false" },
      "requests the company properties once companies are pulled"
    );
    assert
      .dom(
        '[data-name="company_properties"] .d-multi-select-trigger__selected-item'
      )
      .doesNotExist("starts without company properties");
    await selectProperty("company", "Plan");
    await click('[data-test-refresh-properties="company"]');
    assert.deepEqual(
      this.requests.at(-1),
      { object: "company", refresh: "true" },
      "refresh bypasses the cache for that object"
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
          { id: 1, object: "contact", source: "lifecyclestage" },
          { id: 2, object: "contact", source: "jobtitle" },
          { id: 3, object: "company", source: "plan_tier" },
        ],
      },
      "submits the provider, direction, kind, object, schedule and properties of both objects"
    );
  });

  test("keeps the saved selection, including properties HubSpot no longer reports", async function (assert) {
    this.record = {
      ...createHubspotSyncConfiguration(),
      id: 7,
      name: "Customer stages",
      mappings: [
        { id: 1, object: "contact", source: "jobtitle" },
        { id: 2, object: "company", source: "name" },
        { id: 3, object: "contact", source: "removed_property" },
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
      .dom(
        '[data-name="contact_properties"] .d-multi-select-trigger__selected-item'
      )
      .exists({ count: 2 }, "shows every saved contact property");
    assert
      .form()
      .field("pull_companies")
      .hasValue(true, "turns on companies when company properties are saved");
    assert
      .dom(
        '[data-name="company_properties"] .d-multi-select-trigger__selected-item'
      )
      .hasText("Name", "shows the saved company property");
    await click("[data-test-save]");
    assert
      .dom('[data-name="contact_properties"] .form-kit__errors')
      .includesText(
        "removed_property",
        "refuses to save unavailable properties"
      );
  });

  test("explains property loading failures per object, saves without a selection for that object and retries", async function (assert) {
    let failures = 1;
    pretender.get("/salesforce/admin/hubspot/properties.json", (request) => {
      if (request.queryParams.object === "company" && failures-- > 0) {
        return [
          502,
          { "Content-Type": "application/json" },
          JSON.stringify({ errors: ["HubSpot denied access."] }),
        ];
      }
      return propertiesResponse(request.queryParams.object);
    });
    this.saved = null;
    this.save = (configuration) => {
      this.saved = configuration;
      return true;
    };
    await render(
      <template>
        <HubspotSyncConfiguration @onSave={{this.save}} /><DialogHolder />
      </template>
    );

    assert
      .dom('[data-name="contact_properties"]')
      .exists("shows the contact picker when its list loads");
    await formKit().field("pull_companies").toggle();
    assert
      .dom(".hubspot-sync-configuration .form-kit__alert")
      .includesText("HubSpot denied access.", "shows the company error");
    await click("[data-test-save]");
    assert.deepEqual(
      this.saved.mappings,
      [{ id: 1, object: "contact", source: "lifecyclestage" }],
      "saves a contacts-only pull while the company list is unavailable"
    );
    await click('[data-test-refresh-properties="company"]');
    assert
      .dom('[data-name="company_properties"]')
      .exists("shows the company picker once its list loads");
  });

  test("blocks saving while a picked property cannot be checked against its list", async function (assert) {
    pretender.get("/salesforce/admin/hubspot/properties.json", (request) => {
      if (request.queryParams.object === "company") {
        return [502, { "Content-Type": "application/json" }, "{}"];
      }
      return propertiesResponse(request.queryParams.object);
    });
    this.record = {
      ...createHubspotSyncConfiguration(),
      id: 7,
      mappings: [{ id: 1, object: "company", source: "name" }],
    };
    this.saved = null;
    this.save = (configuration) => {
      this.saved = configuration;
      return true;
    };
    await render(
      <template>
        <HubspotSyncConfiguration
          @record={{this.record}}
          @onSave={{this.save}}
        />
      </template>
    );

    await click("[data-test-save]");

    assert.strictEqual(this.saved, null, "does not save");
    assert
      .dom(".form-kit__errors-summary")
      .includesText(
        "Company properties",
        "explains that the picked company property could not be checked"
      );
  });

  test("drops the company properties when companies are no longer pulled", async function (assert) {
    this.record = {
      ...createHubspotSyncConfiguration(),
      id: 7,
      mappings: [
        { id: 1, object: "contact", source: "jobtitle" },
        { id: 2, object: "company", source: "name" },
      ],
    };
    this.saved = null;
    this.save = (configuration) => {
      this.saved = configuration;
      return true;
    };
    await render(
      <template>
        <HubspotSyncConfiguration
          @record={{this.record}}
          @onSave={{this.save}}
        />
      </template>
    );

    await formKit().field("pull_companies").toggle();
    assert
      .dom('[data-name="company_properties"]')
      .doesNotExist("hides the company picker");
    await click("[data-test-save]");

    assert.deepEqual(
      this.saved.mappings,
      [{ id: 1, object: "contact", source: "jobtitle" }],
      "saves only the contact properties"
    );
  });
});
