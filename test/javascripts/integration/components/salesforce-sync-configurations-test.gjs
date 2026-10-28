import { click, fillIn, focus, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import DialogHolder from "discourse/dialog-holder/components/dialog-holder";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender from "discourse/tests/helpers/create-pretender";
import formKit from "discourse/tests/helpers/form-kit-helper";
import SalesforceSyncConfigurations from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-sync-configurations";
import { createDemoConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-demo";
import selectSyncGroups from "../../helpers/select-sync-groups";

module(
  "Integration | Component | SalesforceSyncConfigurations",
  function (hooks) {
    setupRenderingTest(hooks);
    hooks.beforeEach(function () {
      pretender.get("/salesforce/admin/guided-sync/configurations.json", () => [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({ groups: this.groups }),
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
      pretender.get("/salesforce/admin/guided-sync/preview-users.json", () => [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({ users: [] }),
      ]);
      pretender.post("/salesforce/admin/guided-sync/preview.json", () => [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({ user: null, sample: true, rows: [] }),
      ]);
      this.groups = [
        { name: "community-members", user_count: 248 },
        { name: "customers", user_count: 86 },
        { name: "partners", user_count: 32 },
      ];
    });

    test("post sync deep links cannot open the removed wizard", async function (assert) {
      await render(
        <template>
          <SalesforceSyncConfigurations
            @credentialsConfigured={{true}}
            @selectedId="new-posts"
          />
        </template>
      );
      assert
        .dom("[data-test-sync-posts]")
        .isDisabled("shows the disabled choice");
      assert
        .dom(".salesforce-guided-sync")
        .doesNotExist("does not open a wizard");
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
            @credentialsConfigured={{true}}
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
        .dom(".salesforce-guided-sync")
        .doesNotExist("closes the wizard after creation");
      assert.strictEqual(closes, 1, "clears the configuration query parameter");
      await click('[data-test-configuration="saved"] button');
      await click("[data-test-edit-name]");
      await fillIn('[data-name="name"] input', "Updated user sync");
      await click('.salesforce-guided-sync__name-form button[type="submit"]');
      await click("[data-test-save]");
      assert
        .dom('[data-test-configuration="saved"]')
        .includesText("Updated user sync", "shows the updated configuration");
      assert.strictEqual(closes, 2, "returns to the index after editing too");
    });

    test("opens independent saved Lead and Contact configurations", async function (assert) {
      this.records = [
        {
          ...createDemoConfiguration(),
          id: "lead",
          name: "Lead sync",
          groups: ["partners"],
        },
        {
          ...createDemoConfiguration(),
          id: "contact",
          name: "Contact sync",
          object: "Contact",
          groups: ["customers"],
          schedule: "weekly",
        },
      ];
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @credentialsConfigured={{true}}
            @records={{this.records}}
          />
          <DialogHolder />
        </template>
      );
      await click('[data-test-configuration="lead"] button');
      assert
        .dom('[data-test-step="connect"]')
        .doesNotExist("starts directly at scope");
      assert.dom("[data-test-connect-demo]").doesNotExist();
      assert
        .dom('[data-name="groups"]')
        .includesText("partners", "loads the Lead group");
      await selectSyncGroups("community-members");
      await click("[data-test-configurations-back]");
      await click(".dialog-footer .btn-danger");
      await click('[data-test-configuration="contact"] button');
      assert.strictEqual(
        formKit().field("object").value(),
        "Contact",
        "loads the Contact target"
      );
      assert
        .dom('[data-name="groups"]')
        .includesText("customers", "preserves the independent Contact group");
      assert.strictEqual(
        formKit().field("schedule").value(),
        "weekly",
        "preserves the independent Contact schedule"
      );
      await click("[data-test-configurations-back]");
      await click(".dialog-footer .btn-danger");
      await click("[data-test-sync-users]");
      assert.strictEqual(
        formKit().field("object").value(),
        "Lead",
        "starts a new Lead configuration"
      );
      assert
        .dom(".salesforce-guided-sync__heading")
        .includesText("User sync", "provides a default configuration name");
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
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @credentialsConfigured={{false}}
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
            @credentialsConfigured={{true}}
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
          ...createDemoConfiguration(),
          id: "lead",
          name: "Lead sync",
        },
        {
          ...createDemoConfiguration(),
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
            @credentialsConfigured={{true}}
            @records={{this.records}}
            @selectedId="contact"
            @onClose={{this.close}}
          />
        </template>
      );
      assert
        .dom(".salesforce-guided-sync__heading")
        .includesText("Contact sync");
      assert.strictEqual(formKit().field("object").value(), "Contact");
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
          ...createDemoConfiguration(),
          id: "lead",
          name: "<b>Lead sync</b>",
        },
        {
          ...createDemoConfiguration(),
          id: "contact",
          object: "Contact",
          name: "Contact sync",
        },
      ];
      await render(
        <template>
          <SalesforceSyncConfigurations
            @groups={{this.groups}}
            @credentialsConfigured={{true}}
            @records={{this.records}}
          /><DialogHolder />
        </template>
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
  }
);
