import { click, fillIn, focus, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import DialogHolder from "discourse/dialog-holder/components/dialog-holder";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";
import formKit from "discourse/tests/helpers/form-kit-helper";
import SalesforceSyncConfigurations from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-sync-configurations";
import { createDemoConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-demo";

module(
  "Integration | Component | SalesforceSyncConfigurations",
  function (hooks) {
    setupRenderingTest(hooks);

    test("opens independent saved Lead and Contact configurations with workflow editor links", async function (assert) {
      this.records = [
        {
          ...createDemoConfiguration(),
          id: "lead",
          name: "Lead sync",
          group: "partners",
          workflows: [{ id: 81, name: "Lead join", purpose: "join" }],
        },
        {
          ...createDemoConfiguration(),
          id: "contact",
          name: "Contact sync",
          object: "Contact",
          group: "customers",
          schedule: "weekly",
          workflows: [{ id: 82, name: "Contact join", purpose: "join" }],
        },
      ];
      this.connection = { environment: "sandbox" };
      await render(
        <template>
          <SalesforceSyncConfigurations
            @connection={{this.connection}}
            @records={{this.records}}
          />
        </template>
      );
      await click('[data-test-configuration="lead"] button');
      assert
        .dom('[data-test-step="connect"]')
        .doesNotExist("reuses the saved site connection");
      assert.dom("[data-test-connect-demo]").doesNotExist();
      assert
        .dom('[data-test-generated-workflow="81"] a')
        .hasAttribute(
          "href",
          "/admin/plugins/discourse-workflows/workflows/81",
          "links to the real Lead workflow editor"
        );
      assert
        .dom('[data-test-workflow-executions="81"]')
        .hasAttribute(
          "href",
          "/admin/plugins/discourse-workflows/workflows/81/executions",
          "links to the generated workflow execution history"
        );
      await click('[data-test-step="scope"]');
      assert.strictEqual(
        formKit().field("group").value(),
        "partners",
        "loads the Lead group"
      );
      await formKit().field("group").select("community-members");
      await click("[data-test-configurations-back]");
      await click('[data-test-configuration="contact"] button');
      assert
        .dom('[data-test-generated-workflow="82"]')
        .exists("shows the Contact workflow");
      assert
        .dom('[data-test-generated-workflow="81"]')
        .doesNotExist("keeps Lead workflows separate");
      await click('[data-test-step="scope"]');
      assert.strictEqual(
        formKit().field("object").value(),
        "Contact",
        "loads the Contact target"
      );
      assert.strictEqual(
        formKit().field("group").value(),
        "customers",
        "preserves the independent Contact group"
      );
      await click('[data-test-step="behavior"]');
      assert.strictEqual(
        formKit().field("schedule").value(),
        "weekly",
        "preserves the independent Contact schedule"
      );
      await click("[data-test-configurations-back]");
      await click("[data-test-sync-users]");
      await click('[data-test-step="scope"]');
      assert.strictEqual(
        formKit().field("object").value(),
        "Lead",
        "starts a new Lead configuration"
      );
      assert.strictEqual(
        formKit().field("name").value(),
        "User sync",
        "provides a default configuration name"
      );
      await click("[data-test-configurations-back]");
      await click("[data-test-sync-posts]");
      assert
        .dom(".salesforce-case-sync")
        .exists("opens the separate post wizard");
      assert.strictEqual(
        formKit().field("category").value(),
        "support",
        "starts a category-based configuration"
      );
      assert
        .dom('[data-name="group"]')
        .doesNotExist("keeps user group settings out of the post wizard");
    });

    test("connects once and reuses the connection in the next wizard", async function (assert) {
      let connections = 0;
      pretender.put("/salesforce/admin/guided-sync/connection.json", () => {
        connections++;
        return response(200, { connection: { environment: "sandbox" } });
      });
      await render(<template><SalesforceSyncConfigurations /></template>);
      await click("[data-test-sync-users]");
      assert.dom('[data-test-step="connect"]').exists();
      await click("[data-test-connect-demo]");
      assert.strictEqual(connections, 1);
      assert
        .dom('[data-name="group"]')
        .exists("advances to scope after connecting");
      assert.dom('[data-test-step="connect"]').doesNotExist();
      await click("[data-test-configurations-back]");
      assert.dom("[data-test-connection-status]").hasText("Connected");
      await click("[data-test-sync-posts]");
      assert
        .dom('[data-name="category"]')
        .exists("starts the next wizard at scope");
      assert.dom("[data-test-case-connect]").doesNotExist();
      assert.dom('[data-test-case-step="connect"]').doesNotExist();
      assert.strictEqual(
        connections,
        1,
        "does not reconnect for a second configuration"
      );
    });

    test("keeps the configuration name focused while typing in both wizards", async function (assert) {
      this.connection = { environment: "sandbox" };
      await render(
        <template>
          <SalesforceSyncConfigurations @connection={{this.connection}} />
        </template>
      );
      for (const kind of ["users", "posts"]) {
        await click(`[data-test-sync-${kind}]`);
        const selector = '[data-name="name"] input';
        await focus(selector);
        await fillIn(selector, "New");
        assert.dom(selector).isFocused();
        await fillIn(selector, "New configuration name");
        assert.dom(selector).isFocused();
        assert.dom(selector).hasValue("New configuration name");
        await click("[data-test-configurations-back]");
      }
    });

    test("opens the configuration identified by a workflow link", async function (assert) {
      this.connection = { environment: "sandbox" };
      this.records = [
        {
          ...createDemoConfiguration(),
          id: "lead",
          name: "Lead sync",
          workflows: [],
        },
        {
          ...createDemoConfiguration(),
          id: "contact",
          name: "Contact sync",
          object: "Contact",
          workflows: [],
        },
      ];
      let closed = false;
      this.close = () => {
        closed = true;
      };
      await render(
        <template>
          <SalesforceSyncConfigurations
            @connection={{this.connection}}
            @records={{this.records}}
            @selectedId="contact"
            @onClose={{this.close}}
          />
        </template>
      );
      assert.strictEqual(formKit().field("name").value(), "Contact sync");
      assert.strictEqual(formKit().field("object").value(), "Contact");
      await click("[data-test-configurations-back]");
      assert.true(closed, "clears the deep link when closing the editor");
      assert.dom('[data-test-configuration="lead"]').exists();
    });

    test("confirms related workflow deletion and preserves the list when cancelled", async function (assert) {
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
          workflows: [{ id: 81, name: "Lead join" }],
        },
        {
          ...createDemoConfiguration(),
          id: "contact",
          object: "Contact",
          name: "Contact sync",
          workflows: [{ id: 82, name: "Contact join" }],
        },
      ];
      await render(
        <template>
          <SalesforceSyncConfigurations
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
      assert
        .dom(".dialog-body")
        .includesText("Lead join", "lists the related workflow");
      assert
        .dom(".dialog-body")
        .doesNotIncludeText("Contact join", "excludes unrelated workflows");
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
