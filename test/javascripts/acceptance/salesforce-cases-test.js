import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { cloneJSON } from "discourse/lib/object";
import topicFixtures from "discourse/tests/fixtures/topic";
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

acceptance("Salesforce case unlinking", function (needs) {
  needs.user({ admin: false, moderator: true });
  needs.settings({ salesforce_enabled: true });

  let canUnlink;
  let unlinked;
  let rejectUnlink;

  needs.hooks.beforeEach(() => {
    canUnlink = true;
    unlinked = false;
    rejectUnlink = false;
  });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => {
      const topic = cloneJSON(topicFixtures["/t/280/1.json"]);
      topic.can_unlink_salesforce_case = canUnlink;
      topic.salesforce_case = {
        id: 1,
        uid: "case-id",
        number: "123456",
        status: "New",
      };
      return helper.response(topic);
    });
    server.delete("/salesforce/cases/1", () => {
      if (rejectUnlink) {
        return helper.response(500, {
          errors: ["Unable to unlink case"],
        });
      }
      unlinked = true;
      return helper.response(204);
    });
  });

  test("unlinks a case after confirmation", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".salesforce-case__unlink");

    assert
      .dom("#dialog-holder")
      .includesText("#123456", "The confirmation identifies the case");
    assert
      .dom("#dialog-holder")
      .includesText(
        "The case will remain in Salesforce",
        "The confirmation explains that the remote case is preserved"
      );
    assert.false(unlinked, "Unlinking waits for confirmation");

    await click("#dialog-holder .btn-danger");

    assert.true(unlinked, "The local unlink endpoint was called");
    assert
      .dom(".salesforce-case")
      .doesNotExist("The case is unlinked from the topic");
  });

  test("keeps the case when unlinking is cancelled", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".salesforce-case__unlink");
    await click("#dialog-holder .btn-default");

    assert.false(unlinked, "Cancelling keeps the case linked");
    assert.dom(".salesforce-case").exists("The case remains linked");
  });

  test("keeps the case when unlinking fails", async function (assert) {
    rejectUnlink = true;
    await visit("/t/internationalization-localization/280");
    await click(".salesforce-case__unlink");
    await click("#dialog-holder .btn-danger");

    assert
      .dom("#dialog-holder")
      .includesText("Unable to unlink case", "The error is shown");
    assert.dom(".salesforce-case").exists("The case remains linked");
  });

  test("hides unlinking when permission is absent", async function (assert) {
    canUnlink = false;
    await visit("/t/internationalization-localization/280");

    assert
      .dom(".salesforce-case__unlink")
      .doesNotExist("Unlinking is unavailable without permission");
  });
});
