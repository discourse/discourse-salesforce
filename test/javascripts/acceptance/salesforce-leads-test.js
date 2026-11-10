import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { cloneJSON } from "discourse/lib/object";
import topicFixtures from "discourse/tests/fixtures/topic";
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

acceptance("Salesforce Leads menu when enabled", function (needs) {
  needs.user({ admin: true, staff: true });
  needs.settings({ salesforce_enabled: true, salesforce_leads_enabled: true });

  test("shows Lead creation", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click(".show-more-actions");
    await click(".show-post-admin-menu");

    assert.dom(".create-lead").exists("Lead creation is available");
  });
});

acceptance("Salesforce contact unlinking", function (needs) {
  needs.user({ admin: true, staff: true });
  needs.settings({ salesforce_enabled: true });

  let contactId;
  let request;
  let rejectUnlink;
  let unlinked;
  let relinkBeforeResponse;

  needs.hooks.beforeEach(() => {
    contactId = "invalid-contact-id";
    request = null;
    rejectUnlink = false;
    unlinked = false;
    relinkBeforeResponse = false;
  });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => {
      const topic = cloneJSON(topicFixtures["/t/280/1.json"]);
      topic.can_unlink_salesforce_case = true;
      topic.post_stream.posts[0].user_custom_fields = {
        salesforce_contact_id:
          unlinked && !relinkBeforeResponse ? null : contactId,
      };
      return helper.response(topic);
    });
    server.delete("/salesforce/persons/contact", (req) => {
      request = new URLSearchParams(req.requestBody);
      unlinked = !rejectUnlink;
      return rejectUnlink
        ? helper.response(409, {
            errors: ["Association changed. Refresh the page."],
          })
        : helper.response(204);
    });
  });

  test("keeps the contact when confirmation is cancelled", async function (assert) {
    await visit("/t/internationalization-localization/280");
    await click("#post_1 .show-more-actions");
    await click("#post_1 .show-post-admin-menu");
    await click(".unlink-salesforce-contact");
    await click("#dialog-holder .btn-default");

    assert.strictEqual(request, null, "Cancelling sends no unlink request");
    assert
      .dom("#post_1 .salesforce-contact")
      .exists("The Contact remains linked");
  });

  test("shows an association relinked before the unlink response completes", async function (assert) {
    relinkBeforeResponse = true;
    await visit("/t/internationalization-localization/280");
    await click("#post_1 .show-more-actions");
    await click("#post_1 .show-post-admin-menu");
    await click(".unlink-salesforce-contact");
    await click("#dialog-holder .btn-primary");

    assert.true(unlinked, "The unlink request succeeded");
    assert
      .dom("#post_1 .salesforce-contact")
      .exists(
        "Refreshing the posts restores the association relinked by another sync"
      );
  });

  test("keeps the contact when unlinking fails", async function (assert) {
    rejectUnlink = true;
    await visit("/t/internationalization-localization/280");
    await click("#post_1 .show-more-actions");
    await click("#post_1 .show-post-admin-menu");
    await click(".unlink-salesforce-contact");
    await click("#dialog-holder .btn-primary");

    assert
      .dom("#dialog-holder")
      .includesText("Association changed", "The error is visible");
    assert
      .dom("#post_1 .salesforce-contact")
      .exists("The Contact remains linked");
  });
});
