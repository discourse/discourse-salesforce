import { click, fillIn, focus, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import DialogHolder from "discourse/dialog-holder/components/dialog-holder";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender from "discourse/tests/helpers/create-pretender";
import SalesforceSyncConfigurations from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-sync-configurations";
import {
  createHubspotSyncConfiguration,
  createSyncConfiguration,
} from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";
import selectSyncGroups from "../../helpers/select-sync-groups";

module(
  "Integration | Component | SalesforceSyncConfigurations",
  function (hooks) {
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
      pretender.get("/salesforce/admin/guided-sync/fields.json", () => [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
          fields: [
            "Email",
            "FirstName",
            "LastName",
            "Description",
            "Company",
            "LeadSource",
          ].map((name) => ({ name, type: "string" })),
        }),
      ]);
      this.groups = [
        { id: 1, name: "community-members", user_count: 248 },
        { id: 2, name: "customers", user_count: 86 },
        { id: 3, name: "partners", user_count: 32 },
      ];
      this.providers = [{ name: "salesforce", credentials_configured: true }];
      this.allProviders = [
        { name: "salesforce", credentials_configured: true },
        { name: "hubspot", credentials_configured: true },
      ];
    });

    test("post sync deep links cannot open the disabled post configuration", async function (assert) {
      await render(
        <template>
          <SalesforceSyncConfigurations
            @providers={{this.providers}}
            @selectedId="new-posts"
          />
        </template>
      );
      assert.dom("[data-test-sync-users]").hasText("Send users to Salesforce");
      assert
        .dom("[data-test-sync-posts]")
        .isDisabled("shows the disabled choice");
      assert
        .dom(".salesforce-sync-configuration")
        .doesNotExist("does not open an editor");
    });

    test("returns to the configuration list after creating and editing a configuration", async function (assert) {
      let closes = 0;
      this.close = () => closes++;
      const saveResponse = (request) => [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
          configuration: {
            ...JSON.parse(request.requestBody).configuration,
            id: "saved",
          },
        }),
      ];
      pretender.post(
        "/salesforce/admin/guided-sync/configurations.json",
        saveResponse
      );
      pretender.put(
        "/salesforce/admin/guided-sync/configurations/saved.json",
        saveResponse
      );
      await render(
        <template>
          <SalesforceSyncConfigurations
            @providers={{this.providers}}
            @groups={{this.groups}}
            @onClose={{this.close}}
          />
        </template>
      );
      await click("[data-test-sync-users]");
      await selectSyncGroups("customers");
      await click("[data-test-save]");
      assert
        .dom('[data-test-configuration="saved"]')
        .exists("shows the saved configuration in the list");
      assert
        .dom(".salesforce-sync-configuration")
        .doesNotExist("closes the editor after creation");
      assert.strictEqual(closes, 1, "clears the configuration query parameter");
      await click('[data-test-configuration="saved"] button');
      await click("[data-test-edit-name]");
      await fillIn('[data-name="name"] input', "Updated user export");
      await click('.sync-configuration-heading__form button[type="submit"]');
      await click("[data-test-save]");
      assert
        .dom('[data-test-configuration="saved"]')
        .includesText("Updated user export", "shows the updated configuration");
      assert.strictEqual(closes, 2, "returns to the index after editing too");
    });

    test("opens independent saved Lead and Contact configurations", async function (assert) {
      this.records = [
        {
          ...createSyncConfiguration(),
          id: "lead",
          name: "Lead sync",
          groups: ["partners"],
          group_ids: [3],
        },
        {
          ...createSyncConfiguration(),
          id: "contact",
          name: "Contact sync",
          object: "Contact",
          groups: ["customers"],
          group_ids: [2],
          schedule: "weekly",
        },
      ];
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.providers}}
            @records={{this.records}}
          />
          <DialogHolder />
        </template>
      );
      await click('[data-test-configuration="lead"] button');
      assert
        .dom('[data-name="group_ids"]')
        .includesText("partners", "loads the Lead group");
      await selectSyncGroups("community-members");
      await click("[data-test-configurations-back]");
      await click(".dialog-footer .btn-danger");
      await click('[data-test-configuration="contact"] button');
      assert
        .dom('[data-name="object"] .form-kit__control-menu-trigger')
        .hasText("Contact", "loads the Contact target");
      assert
        .dom('[data-name="group_ids"]')
        .includesText("customers", "preserves the independent Contact group");
      assert
        .dom('[data-name="schedule"] .form-kit__control-menu-trigger')
        .hasText("weekly", "preserves the independent Contact schedule");
      await click("[data-test-configurations-back]");
      await click(".dialog-footer .btn-danger");
      await click("[data-test-sync-users]");
      assert
        .dom('[data-name="object"] .form-kit__control-menu-trigger')
        .hasText("Lead", "starts a new Lead configuration");
      assert
        .dom(".salesforce-sync-configuration__heading")
        .includesText("Send users", "provides a default configuration name");
      await click("[data-test-configurations-back]");
      await click(".dialog-footer .btn-danger");
      assert
        .dom("[data-test-sync-posts]")
        .isDisabled("post syncing is not available");
      assert
        .dom("[data-test-sync-posts]")
        .includesText("Coming soon", "explains its availability");
    });

    test("requires configured plugin credentials before opening setup", async function (assert) {
      this.noCredentials = [
        { name: "salesforce", credentials_configured: false },
      ];
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.noCredentials}}
          />
        </template>
      );
      assert
        .dom("[data-test-credentials-required]")
        .exists("explains the missing credentials");
      assert
        .dom("[data-test-sync-users]")
        .doesNotExist("hides setup until credentials are configured");
      assert
        .dom('a[href="/admin/plugins/discourse-salesforce/settings"]')
        .exists("links to plugin settings");
    });

    test("keeps the configuration name focused while typing", async function (assert) {
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.providers}}
          /><DialogHolder />
        </template>
      );
      await click("[data-test-sync-users]");
      await click("[data-test-edit-name]");
      const selector = '[data-name="name"] input';
      await focus(selector);
      await fillIn(selector, "New");
      assert.dom(selector).isFocused();
      await fillIn(selector, "New configuration name");
      assert.dom(selector).isFocused();
      assert.dom(selector).hasValue("New configuration name");
      await click("[data-test-configurations-back]");
      await click(".dialog-footer .btn-danger");
    });

    test("opens the configuration identified by a direct link", async function (assert) {
      this.records = [
        {
          ...createSyncConfiguration(),
          id: "lead",
          name: "Lead sync",
        },
        {
          ...createSyncConfiguration(),
          id: "contact",
          name: "Contact sync",
          object: "Contact",
        },
      ];
      let closed = false;
      this.close = () => {
        closed = true;
      };
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.providers}}
            @records={{this.records}}
            @selectedId="contact"
            @onClose={{this.close}}
          />
          <DialogHolder />
        </template>
      );
      assert
        .dom(".salesforce-sync-configuration__heading")
        .includesText("Contact sync");
      assert
        .dom('[data-name="object"] .form-kit__control-menu-trigger')
        .hasText("Contact");
      await click("[data-test-configurations-back]");
      await click(".dialog-footer .btn-danger");
      assert.true(closed, "clears the deep link when closing the editor");
      assert.dom('[data-test-configuration="lead"]').exists();
    });

    test("confirms configuration deletion and preserves the list when cancelled", async function (assert) {
      let requests = 0;
      pretender.delete(
        "/salesforce/admin/guided-sync/configurations/lead.json",
        () => {
          requests++;
          return [204, {}, ""];
        }
      );
      this.records = [
        {
          ...createSyncConfiguration(),
          id: "lead",
          name: "<b>Lead sync</b>",
          active: true,
        },
        {
          ...createSyncConfiguration(),
          id: "contact",
          object: "Contact",
          name: "Contact sync",
          active: true,
          sync_status: { error: "Salesforce::InvalidApiResponse" },
        },
        {
          ...createSyncConfiguration(),
          id: "stale-connection",
          name: "Previous Salesforce account",
          connection_changed: true,
        },
      ];
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.providers}}
            @records={{this.records}}
          /><DialogHolder />
        </template>
      );
      assert
        .dom(
          '[data-test-configuration="lead"] .salesforce-sync-configurations__status'
        )
        .doesNotExist("successful configurations do not need a status label");
      assert
        .dom(
          '[data-test-configuration="contact"] .salesforce-sync-configurations__status'
        )
        .hasText(
          "Sync failed — check background job errors",
          "keeps errors visible"
        );
      assert
        .dom(
          '[data-test-configuration="stale-connection"] .salesforce-sync-configurations__status'
        )
        .hasText(
          "CRM connection changed. Configure and save again to resume syncing."
        );
      await click('[data-test-delete-configuration="lead"]');
      assert
        .dom(".dialog-body")
        .includesText(
          "<b>Lead sync</b>",
          "names the configuration using escaped text"
        );
      assert
        .dom(".dialog-body b")
        .doesNotExist("treats configuration names as text");
      await click(".dialog-footer .btn-default");
      assert.strictEqual(requests, 0, "cancelling sends no deletion request");
      assert
        .dom('[data-test-configuration="lead"]')
        .exists("keeps the configuration after cancellation");
      await click('[data-test-delete-configuration="lead"]');
      await click(".dialog-footer .btn-danger");
      assert.strictEqual(requests, 1, "deletes only after confirmation");
      assert
        .dom('[data-test-configuration="lead"]')
        .doesNotExist("removes the deleted configuration from the list");
      assert
        .dom('[data-test-configuration="contact"]')
        .exists("keeps the other configuration");
    });

    test("offers HubSpot contact pull only while the provider is enabled and unconfigured", async function (assert) {
      pretender.get("/salesforce/admin/hubspot/contact-properties.json", () => [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
          properties: [{ name: "lifecyclestage", label: "Lifecycle stage" }],
        }),
      ]);
      this.records = [];
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.providers}}
            @records={{this.records}}
          />
        </template>
      );
      assert
        .dom("[data-test-sync-contacts]")
        .doesNotExist("hides HubSpot while the provider is disabled");

      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.allProviders}}
            @records={{this.records}}
          />
          <DialogHolder />
        </template>
      );
      assert
        .dom("[data-test-sync-contacts]")
        .hasText("Pull contacts from HubSpot", "offers the HubSpot pull");
      await click("[data-test-sync-contacts]");
      assert
        .dom(".hubspot-sync-configuration .d-page-subheader__title")
        .hasText(
          "Pull contacts",
          "opens the HubSpot editor with a default name"
        );
      await click("[data-test-configurations-back]");
      await click(".dialog-footer .btn-danger");

      this.records = [
        {
          ...createHubspotSyncConfiguration(),
          id: "hubspot",
          name: "Pull contacts",
        },
      ];
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.allProviders}}
            @records={{this.records}}
          />
        </template>
      );
      assert
        .dom("[data-test-sync-contacts]")
        .isDisabled("allows a single HubSpot pull");
      assert.dom("[data-test-sync-contacts]").hasText("Already configured");
      assert
        .dom('[data-test-configuration="hubspot"]')
        .includesText("Pull contacts from HubSpot", "labels the type");
      assert
        .dom(
          '[data-test-configuration="hubspot"] [data-test-configuration-scope]'
        )
        .includesText("All users", "pulls apply to every user");
      await click('[data-test-configuration="hubspot"] button');
      assert
        .dom(".hubspot-sync-configuration")
        .exists("opens saved HubSpot configurations in the HubSpot editor");
    });

    test("opens a new HubSpot configuration from a direct link", async function (assert) {
      pretender.get("/salesforce/admin/hubspot/contact-properties.json", () => [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({ properties: [] }),
      ]);
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @providers={{this.allProviders}}
            @selectedId="new-hubspot-users"
          />
        </template>
      );
      assert.dom(".hubspot-sync-configuration").exists();
      assert.dom(".salesforce-sync-configuration").doesNotExist();
    });
  }
);
