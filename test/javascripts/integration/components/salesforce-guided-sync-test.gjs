import { click, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import formKit from "discourse/tests/helpers/form-kit-helper";
import SalesforceGuidedSync from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-guided-sync";

module("Integration | Component | SalesforceGuidedSync", function (hooks) {
  setupRenderingTest(hooks);

  test("guided setup previews ownership rules and enables a simulated sync", async function (assert) {
    await render(<template><SalesforceGuidedSync /></template>);

    assert.dom("[data-test-continue]").isDisabled();
    await click("[data-test-connect-demo]");
    await click("[data-test-continue]");
    await formKit().field("group").select("customers");
    await formKit().field("object").select("Contact");
    await click("[data-test-continue]");

    assert
      .dom(
        '[data-name="mappings.5.destination"] .form-kit__control-menu-trigger'
      )
      .includesText(
        "Company_Name__c",
        "shows the Contact-specific destination"
      );
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
      .dom('[data-test-preview-field="Posts_Created__c"]')
      .includesText("Updated");

    await formKit().field("previewUser").select("kai");
    assert.dom('[data-test-preview-field="LastName"]').includesText("Kai");
    assert.dom('[data-test-preview-field="FirstName"] strong').hasText("—");

    await click("[data-test-continue]");
    assert.dom(".salesforce-guided-sync__stats").doesNotExist();
    assert.dom("[data-test-retry-failure]").doesNotExist();
    await click('[data-test-step="mapping"]');
    await formKit().field("mappings.5.policy").select("keep");
    await click('[data-test-step="review"]');
    await click("[data-test-continue]");
    assert.dom("[data-test-demo-message]").includesText("Demo changes saved");
    assert.dom("[data-test-retry-failure]").doesNotExist();
  });

  test("moving a destination requires repairing its previous mapping", async function (assert) {
    await render(<template><SalesforceGuidedSync /></template>);
    await click("[data-test-connect-demo]");
    await click('[data-test-step="mapping"]');

    await formKit().field("mappings.5.destination").select("Description");
    assert
      .dom(
        '[data-name="mappings.2.destination"] .form-kit__control-menu-trigger'
      )
      .includesText("Choose a field", "clears the previous destination");
    assert
      .dom('[data-test-mapping="3"]')
      .includesText("This destination moved");
    assert.dom("[data-test-continue]").isDisabled();

    await formKit().field("mappings.5.destination").select("Company");
    await formKit().field("mappings.2.destination").select("Description");
    assert.dom("[data-test-continue]").isEnabled();

    await formKit().field("mappings.3.destination").select("Last_Seen__c");
    assert.dom(".alert-error").includesText("types that match");
    assert.dom("[data-test-continue]").isDisabled();
  });
});
