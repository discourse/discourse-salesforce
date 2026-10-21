import { click, render } from "@ember/test-helpers";
import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import formKit from "discourse/tests/helpers/form-kit-helper";
import SalesforceCaseSync from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-case-sync";
import { createCaseDemoConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/guided-case-sync-demo";

module("Integration | Component | SalesforceCaseSync", function (hooks) {
  setupRenderingTest(hooks);

  test("configures a support category, case fields, and independent public reply directions", async function (assert) {
    this.record = {
      ...createCaseDemoConfiguration(),
      name: "Support case sync",
    };
    this.save = (configuration) => {
      this.savedConfiguration = structuredClone(configuration);
      return true;
    };
    await render(
      <template>
        <SalesforceCaseSync @record={{this.record}} @onSave={{this.save}} />
      </template>
    );
    assert
      .dom("[data-test-case-continue]")
      .isDisabled("requires the demo connection");
    await click("[data-test-case-connect]");
    await click("[data-test-case-continue]");
    await formKit().field("category").select("enterprise-support");
    await click("[data-test-case-continue]");
    assert
      .dom('[data-test-case-mapping="attachments"]')
      .includesText(
        "Files linked to the Case",
        "treats attachments as linked files"
      );
    await formKit()
      .field("mappings.2.destination")
      .select("Product_Version__c");
    assert
      .dom("[data-test-case-continue]")
      .isDisabled("prevents duplicate destinations");
    await formKit().field("mappings.2.destination").select("Community_Tags__c");
    await formKit()
      .field("mappings.3.destination")
      .select("Product_Version__c");
    await click("[data-test-case-continue]");
    await formKit().field("inboundReplies").toggle();
    assert
      .dom(".salesforce-case-sync")
      .includesText(
        "Internal Salesforce notes",
        "explains the public response boundary"
      );
    await click("[data-test-case-continue]");
    assert
      .dom('[data-test-case-preview="version"]')
      .includesText("3.4.1", "previews the structured version field");
    assert
      .dom('[data-test-case-preview="attachments"]')
      .includesText("screenshot.png", "previews attachments");
    assert
      .dom(".salesforce-case-sync")
      .doesNotIncludeText(
        "Agent on Salesforce:",
        "omits inbound reply preview when disabled"
      );
    await click("[data-test-case-continue]");
    assert.strictEqual(
      this.savedConfiguration.category,
      "enterprise-support",
      "saves the chosen category"
    );
    assert.true(
      this.savedConfiguration.outboundReplies,
      "keeps outbound replies enabled"
    );
    assert.false(
      this.savedConfiguration.inboundReplies,
      "saves the independent inbound preference"
    );
    assert
      .dom("[data-test-case-saved]")
      .doesNotExist("does not show a success banner");
  });
});
