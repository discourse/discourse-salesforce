import { click, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import DialogHolder from "discourse/dialog-holder/components/dialog-holder";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender from "discourse/tests/helpers/create-pretender";
import formKit from "discourse/tests/helpers/form-kit-helper";
import CrmInboundSyncConfiguration from "discourse/plugins/discourse-salesforce/discourse/components/crm-inbound-sync-configuration";
import { createPullConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const HUBSPOT_PROPERTIES = {
  contact: [
    {
      name: "firstname+lastname",
      label: "Full name (First Name + Last Name)",
      type: "string",
      source_type: "text",
    },
    {
      name: "website",
      label: "Website URL",
      type: "string",
      source_type: "text",
    },
    {
      name: "lifecyclestage",
      label: "Lifecycle stage",
      type: "enumeration",
      source_type: "text",
    },
    {
      name: "jobtitle",
      label: "Job title",
      type: "string",
      source_type: "text",
    },
    { name: "city", label: "City", type: "string", source_type: "text" },
    {
      name: "renewal",
      label: "Renewal date",
      type: "date",
      source_type: "date",
    },
  ],
  company: [
    { name: "name", label: "Name", type: "string", source_type: "text" },
    {
      name: "domain",
      label: "Company domain",
      type: "string",
      source_type: "text",
    },
    {
      name: "plan_tier",
      label: "Plan tier",
      type: "string",
      source_type: "text",
    },
  ],
};

const SALESFORCE_FIELDS = [
  { name: "Name", label: "Full Name", type: "string", source_type: "text" },
  { name: "Website", label: "Website", type: "url", source_type: "text" },
  { name: "Title", label: "Title", type: "string", source_type: "text" },
  {
    name: "NumberOfEmployees",
    label: "Employees",
    type: "int",
    source_type: "number",
  },
];

const DESTINATIONS = [
  {
    id: "name",
    name: "Name",
    type: "text",
    group: "details",
    accepts: ["text", "number"],
  },
  {
    id: "bio",
    name: "Bio",
    type: "text",
    group: "details",
    accepts: ["text", "number"],
  },
  {
    id: "website",
    name: "Website",
    type: "text",
    group: "details",
    accepts: ["text", "number"],
  },
  {
    id: "user_field_7",
    name: "Job title",
    type: "text",
    group: "custom",
    accepts: ["text", "number"],
  },
  {
    id: "user_field_8",
    name: "Renewal",
    type: "date",

    group: "custom",
    accepts: ["date"],
  },
];

const TARGETS = [
  { provider: "hubspot", object: "contact" },
  { provider: "hubspot", object: "company" },
  { provider: "salesforce", object: "Lead" },
  { provider: "salesforce", object: "Contact", configured: true },
];

function json(body) {
  return [200, { "Content-Type": "application/json" }, JSON.stringify(body)];
}

async function chooseMenuItem(selector, value) {
  await click(`${selector} .form-kit__control-menu-trigger`);
  await click(`.form-kit__control-menu-item[data-value="${value}"] button`);
}

async function chooseSource(index, name) {
  await chooseMenuItem(`[data-name="pull_mappings.${index}.source"]`, name);
}

async function chooseDestination(index, id) {
  await chooseMenuItem(`[data-name="pull_mappings.${index}.destination"]`, id);
}

module(
  "Integration | Component | CrmInboundSyncConfiguration",
  function (hooks) {
    setupRenderingTest(hooks);

    hooks.beforeEach(function () {
      this.targets = TARGETS;
      this.requests = [];
      this.saved = null;
      this.save = (configuration) => {
        this.saved = configuration;
        return true;
      };
      pretender.get("/salesforce/admin/hubspot/properties.json", (request) => {
        this.requests.push({ url: "hubspot", ...request.queryParams });
        const object = request.queryParams.object;
        return json({
          properties: HUBSPOT_PROPERTIES[object],
          ...(object === "contact" ? { destinations: DESTINATIONS } : {}),
        });
      });
      pretender.get("/salesforce/admin/guided-sync/fields.json", (request) => {
        this.requests.push({ url: "salesforce", ...request.queryParams });
        return json({ fields: SALESFORCE_FIELDS, destinations: DESTINATIONS });
      });
    });

    test("pulls HubSpot contacts with name and website defaults", async function (assert) {
      await render(
        <template>
          <CrmInboundSyncConfiguration
            @targets={{this.targets}}
            @onSave={{this.save}}
          />
        </template>
      );

      assert.deepEqual(
        [
          ...document.querySelectorAll(".crm-pull-configuration__section h3"),
        ].map((heading) => heading.textContent.trim()),
        ["What to pull", "When to pull", "Fields to pull"],
        "asks what, then when, then which fields"
      );
      assert
        .dom(".d-page-subheader__title")
        .hasText("Pull HubSpot contacts", "names the pull after its target");
      assert.deepEqual(
        this.requests,
        [
          {
            url: "hubspot",
            object: "contact",
            direction: "inbound",
            refresh: "false",
          },
        ],
        "loads the contact fields"
      );
      assert
        .dom('[data-name="pull_mappings.0.source"]')
        .includesText("Full name", "copies the full name by default");
      assert
        .dom('[data-name="pull_mappings.0.destination"]')
        .includesText("Name");
      assert
        .dom('[data-name="pull_mappings.0.policy"]')
        .includesText("Keep Discourse value", "keeps names users entered");
      assert
        .dom('[data-name="pull_mappings.1.source"]')
        .includesText("Website URL", "copies the website by default");
      assert
        .dom("[data-test-user-pull-note]")
        .exists("notes that users are also matched individually");
      await click('[data-name="target"] .form-kit__control-menu-trigger');
      assert
        .dom('[data-test-pull-target="salesforce:Contact"]')
        .includesText("Already configured")
        .isDisabled("offers each CRM object once");
      await click(
        '.form-kit__control-menu-item[data-value="hubspot:contact"] .btn'
      );

      await formKit().field("backfill").toggle();
      await formKit().field("schedule").select("weekly");
      await click("[data-test-save]");

      assert.deepEqual(
        this.saved,
        {
          ...createPullConfiguration({
            provider: "hubspot",
            object: "contact",
          }),
          name: "Pull HubSpot contacts",
          backfill: false,
          schedule: "weekly",
          mappings: [
            {
              id: 1,
              object: "contact",
              source: "firstname+lastname",
              destination: "name",
              policy: "keep",
            },
            {
              id: 2,
              object: "contact",
              source: "website",
              destination: "website",
              policy: "keep",
            },
          ],
        },
        "submits one mapping per row"
      );
    });

    test("drops default copies into fields this site cannot fill", async function (assert) {
      pretender.get("/salesforce/admin/hubspot/properties.json", () =>
        json({
          properties: HUBSPOT_PROPERTIES.contact,
          destinations: DESTINATIONS.filter(({ id }) => id !== "name"),
        })
      );
      // The configurations page passes the unsaved configuration it is creating.
      this.record = createPullConfiguration({
        provider: "hubspot",
        object: "contact",
      });
      await render(
        <template>
          <CrmInboundSyncConfiguration
            @record={{this.record}}
            @targets={{this.targets}}
            @onSave={{this.save}}
          />
        </template>
      );

      assert
        .dom('[data-name="pull_mappings.0.destination"]')
        .includesText("Don’t copy", "skips the name set by the login provider");
      assert
        .dom('[data-name="pull_mappings.1.destination"]')
        .includesText("Website", "keeps the other defaults");
    });

    test("copies fields into compatible Discourse fields and moves duplicates between rows", async function (assert) {
      this.record = {
        ...createPullConfiguration({ provider: "hubspot", object: "contact" }),
        mappings: [{ id: 1, object: "contact", source: "lifecyclestage" }],
      };
      await render(
        <template>
          <CrmInboundSyncConfiguration
            @record={{this.record}}
            @targets={{this.targets}}
            @onSave={{this.save}}
          />
        </template>
      );

      await click("[data-test-add-pull-field]");
      await chooseSource(1, "renewal");
      await click(
        '[data-name="pull_mappings.1.destination"] .form-kit__control-menu-trigger'
      );
      assert
        .dom(".salesforce-source-menu__option")
        .exists(
          { count: 2 },
          "offers only the fields that accept a date, plus not copying"
        );
      await click(
        '.form-kit__control-menu-item[data-value="user_field_8"] button'
      );

      await click("[data-test-add-pull-field]");
      await chooseSource(2, "jobtitle");
      await chooseDestination(2, "user_field_7");
      await chooseMenuItem('[data-name="pull_mappings.2.policy"]', "keep");
      await chooseDestination(0, "user_field_7");
      assert
        .dom('[data-name="pull_mappings.2.destination"]')
        .includesText(
          "moved to another row",
          "explains why the row lost its field"
        );
      await chooseDestination(2, "bio");

      await click(
        '[data-name="pull_mappings.0.source"] .form-kit__control-menu-trigger'
      );
      assert
        .dom('.form-kit__control-menu-item[data-value="jobtitle"]')
        .includesText(
          "Already pulled in another row",
          "marks fields that another row pulls"
        );
      await click(
        '.form-kit__control-menu-item[data-value="lifecyclestage"] button'
      );

      await chooseSource(1, "city");
      assert
        .dom('[data-name="pull_mappings.1.destination"]')
        .includesText(
          "Don’t copy",
          "clears a Discourse field that no longer accepts the CRM field"
        );
      await click("[data-test-save]");

      assert.deepEqual(
        this.saved.mappings,
        [
          {
            id: 1,
            object: "contact",
            source: "lifecyclestage",
            destination: "user_field_7",
            policy: "overwrite",
          },
          { id: 2, object: "contact", source: "city" },
          {
            id: 3,
            object: "contact",
            source: "jobtitle",
            destination: "bio",
            policy: "keep",
          },
        ],
        "submits each row with its Discourse field and policy"
      );
      assert.false(
        "pull_mappings" in this.saved,
        "does not submit the form-only rows"
      );
    });

    test("keeps saved rows, including fields the CRM no longer reports", async function (assert) {
      this.record = {
        ...createPullConfiguration({ provider: "hubspot", object: "contact" }),
        id: 7,
        name: "Customer stages",
        mappings: [
          {
            id: 1,
            object: "contact",
            source: "jobtitle",
            destination: "user_field_7",
            policy: "keep",
          },
          { id: 2, object: "contact", source: "removed_property" },
        ],
      };
      await render(
        <template>
          <CrmInboundSyncConfiguration
            @record={{this.record}}
            @targets={{this.targets}}
            @onSave={{this.save}}
          />
        </template>
      );

      assert.dom(".d-page-subheader__title").hasText("Customer stages");
      assert
        .dom('[data-name="target"] .form-kit__control-menu-trigger')
        .isDisabled("keeps the target of a saved pull");
      assert
        .dom('[data-name="pull_mappings.0.destination"]')
        .includesText("Job title", "shows the saved Discourse field");
      assert
        .dom('[data-name="pull_mappings.0.policy"]')
        .includesText("Keep Discourse value", "shows the saved policy");
      await click("[data-test-save]");
      assert.strictEqual(this.saved, null, "does not save");
      assert
        .dom('[data-name="pull_mappings.1.source"] .form-kit__errors')
        .includesText("removed_property", "refuses to save unavailable fields");
    });

    test("explains a field loading failure, blocks saving and retries", async function (assert) {
      let failures = 1;
      pretender.get("/salesforce/admin/hubspot/properties.json", () => {
        if (failures-- > 0) {
          return [
            502,
            { "Content-Type": "application/json" },
            JSON.stringify({ errors: ["HubSpot denied access."] }),
          ];
        }
        return json({
          properties: HUBSPOT_PROPERTIES.contact,
          destinations: DESTINATIONS,
        });
      });
      await render(
        <template>
          <CrmInboundSyncConfiguration
            @targets={{this.targets}}
            @onSave={{this.save}}
          /><DialogHolder />
        </template>
      );

      assert
        .dom(".crm-pull-configuration .form-kit__alert")
        .includesText("HubSpot denied access.", "shows the error");
      await click("[data-test-save]");
      assert.strictEqual(this.saved, null, "does not save unchecked fields");

      await click("[data-test-refresh-pull-fields]");
      assert
        .dom('[data-name="pull_mappings.0.source"]')
        .exists("shows the rows once the fields load");
      await click("[data-test-save]");
      assert.strictEqual(
        this.saved.mappings.length,
        2,
        "saves after the retry"
      );
    });
  }
);
