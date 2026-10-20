import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

acceptance("Salesforce Cases menu for admins", function (needs) {
  needs.user({ admin: true, moderator: false });
  needs.settings({
    salesforce_enabled: true,
    salesforce_allow_moderators_to_create_cases: false,
  });

  test("shows case creation with moderator access disabled", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".toggle-admin-menu");

    assert
      .dom(".topic-admin-salesforce-case")
      .exists("Admins can create cases by default");
  });
});

acceptance("Salesforce Cases menu for moderators", function (needs) {
  needs.user({ admin: false, moderator: true });
  needs.settings({
    salesforce_enabled: true,
    salesforce_allow_moderators_to_create_cases: false,
  });

  test("hides case creation by default", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".toggle-admin-menu");

    assert
      .dom(".topic-admin-salesforce-case")
      .doesNotExist("Moderators cannot create cases by default");
  });
});

acceptance("Salesforce Cases menu with moderator access", function (needs) {
  needs.user({ admin: false, moderator: true });
  needs.settings({
    salesforce_enabled: true,
    salesforce_allow_moderators_to_create_cases: true,
  });
  needs.pretender((server, helper) => {
    server.post("/salesforce/cases/sync", () =>
      helper.response({ case: { id: 1, number: "123456", status: "New" } })
    );
  });

  test("allows moderators to create and sync cases", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".toggle-admin-menu");

    assert
      .dom(".topic-admin-salesforce-case")
      .hasText("Create Case", "Moderators can create cases when enabled");

    await click(".topic-admin-salesforce-case");
    await click(".toggle-admin-menu");

    assert
      .dom(".topic-admin-salesforce-case")
      .hasText("Sync Case", "Existing cases can be synced");
  });
});
