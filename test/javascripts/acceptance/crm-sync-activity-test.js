import { currentURL, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

for (const [scenario, guidedSync, salesforce, hubspot, visible] of [
  ["Salesforce only", true, true, false, true],
  ["HubSpot only", true, false, true, true],
  ["both providers disabled", true, false, false, false],
  ["guided sync disabled", false, true, true, false],
]) {
  acceptance(`CRM sync activity with ${scenario}`, function (needs) {
    needs.user({ admin: true });
    needs.settings({
      enable_guided_sync_configuration: guidedSync,
      salesforce_enabled: salesforce,
      hubspot_enabled: hubspot,
    });
    let historyRequests;
    needs.hooks.beforeEach(() => {
      historyRequests = 0;
    });
    needs.pretender((server, helper) => {
      server.get("/admin/plugins/discourse-salesforce.json", () =>
        helper.response({
          id: "discourse-salesforce",
          name: "discourse-salesforce",
          enabled: salesforce || hubspot,
        })
      );
      server.get("/admin/config/site_settings.json", () =>
        helper.response({ site_settings: [] })
      );
      server.get("/salesforce/admin/guided-sync/activity.json", () => {
        historyRequests++;
        return helper.response({ attempts: [], next_before: null });
      });
    });

    test("opening the activity URL respects guided sync availability", async function (assert) {
      await visit("/admin/plugins/discourse-salesforce/activity");
      assert.strictEqual(historyRequests, visible ? 1 : 0);
      assert.strictEqual(
        currentURL(),
        visible
          ? "/admin/plugins/discourse-salesforce/activity"
          : "/admin/plugins/discourse-salesforce/settings"
      );
      const count = visible ? 1 : 0;
      assert.dom(".crm-sync-activity").exists({ count });
      assert
        .dom(
          ".admin-plugin-config-page__top-nav-item a[href='/admin/plugins/discourse-salesforce/activity']"
        )
        .exists({ count });
    });
  });
}
