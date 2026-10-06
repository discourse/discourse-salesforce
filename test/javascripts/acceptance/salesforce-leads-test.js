import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

acceptance("Salesforce Leads menu", function (needs) {
  needs.user({ admin: true, staff: true });
  needs.settings({ salesforce_enabled: true });
  needs.site({ salesforce_leads_enabled: false });

  test("hides Lead creation while keeping Contact creation", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".show-more-actions");
    await click(".show-post-admin-menu");

    assert.dom(".create-lead").doesNotExist("Lead creation is unavailable");
    assert.dom(".create-contact").exists("Contact creation remains available");
  });
});

acceptance("Salesforce Leads menu with group members", function (needs) {
  needs.user({ admin: true, staff: true });
  needs.settings({ salesforce_enabled: true });
  needs.site({ salesforce_leads_enabled: true });

  test("shows Lead creation", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".show-more-actions");
    await click(".show-post-admin-menu");

    assert.dom(".create-lead").exists("Lead creation is available");
  });
});
