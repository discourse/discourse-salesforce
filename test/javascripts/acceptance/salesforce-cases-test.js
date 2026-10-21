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

acceptance("Salesforce case deletion", function (needs) {
  needs.user({ admin: false, moderator: false });
  needs.settings({ salesforce_enabled: true });

  let canDelete;
  let deleted;
  let rejectDeletion;

  needs.hooks.beforeEach(() => {
    canDelete = true;
    deleted = false;
    rejectDeletion = false;
  });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => {
      const topic = cloneJSON(topicFixtures["/t/280/1.json"]);
      topic.can_delete_salesforce_case = canDelete;
      topic.salesforce_case = {
        id: 1,
        uid: "case-id",
        number: "123456",
        status: "New",
      };
      return helper.response(topic);
    });
    server.delete("/salesforce/cases/1", () => {
      if (rejectDeletion) {
        return helper.response(422, {
          errors: ["Salesforce rejected deletion"],
        });
      }
      deleted = true;
      return helper.response(204);
    });
  });

  test("deletes and unlinks a case after confirmation", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".salesforce-case__delete");

    assert
      .dom("#dialog-holder")
      .includesText("#123456", "The confirmation identifies the case");
    assert.false(deleted, "Deletion waits for confirmation");

    await click("#dialog-holder .btn-danger");

    assert.true(deleted, "The remote deletion endpoint was called");
    assert
      .dom(".salesforce-case")
      .doesNotExist("The case is unlinked from the topic");
  });

  test("keeps the case when deletion is cancelled", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".salesforce-case__delete");
    await click("#dialog-holder .btn-default");

    assert.false(deleted, "Cancelling leaves the remote case untouched");
    assert.dom(".salesforce-case").exists("The case remains linked");
  });

  test("keeps the case when Salesforce rejects deletion", async function (assert) {
    rejectDeletion = true;
    await visit("/t/internationalization-localization/280");
    await click(".salesforce-case__delete");
    await click("#dialog-holder .btn-danger");

    assert
      .dom("#dialog-holder")
      .includesText("Salesforce rejected deletion", "The error is shown");
    assert.dom(".salesforce-case").exists("The case remains linked");
  });

  test("hides deletion when permission is absent", async function (assert) {
    canDelete = false;
    await visit("/t/internationalization-localization/280");

    assert
      .dom(".salesforce-case__delete")
      .doesNotExist("Deletion is unavailable without permission");
  });
});
