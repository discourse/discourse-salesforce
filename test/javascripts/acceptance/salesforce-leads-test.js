import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

acceptance("Salesforce Leads menu", function (needs) {
  needs.user({ admin: true, staff: true });
  needs.settings({ salesforce_enabled: true, salesforce_leads_enabled: false });

  test("hides Lead creation while keeping Contact creation", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".show-more-actions");
    await click(".show-post-admin-menu");

    assert.dom(".create-lead").doesNotExist("Lead creation is unavailable");
    assert.dom(".create-contact").exists("Contact creation remains available");
  });
});
