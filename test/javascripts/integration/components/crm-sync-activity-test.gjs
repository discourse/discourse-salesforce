import { click, fillIn, find, render, waitUntil } from "@ember/test-helpers";
import { module, test } from "qunit";
import sinon from "sinon";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender from "discourse/tests/helpers/create-pretender";
import selectKit from "discourse/tests/helpers/select-kit-helper";
import stubIntersectionObserver from "discourse/tests/helpers/stub-intersection-observer";
import {
  disableLoadMoreObserver,
  enableLoadMoreObserver,
} from "discourse/ui-kit/d-load-more";
import CrmSyncActivity from "discourse/plugins/discourse-salesforce/discourse/components/crm-sync-activity";

module("Integration | Component | CrmSyncActivity", function (hooks) {
  setupRenderingTest(hooks);
  hooks.afterEach(() => disableLoadMoreObserver());

  test("opens details below the selected attempt and links to its configuration", async function (assert) {
    this.model = {
      attempts: [
        {
          id: 2,
          username: "jane",
          provider: "salesforce",
          outcome: "skipped",
          reason: "skipped_existing_contact",
          configuration: { id: 12, name: "Send members as leads" },
          created_at: "2026-11-11T08:00:00Z",
          direction: "outbound",
          object: "Lead",
        },
        {
          id: 1,
          username: "jane",
          provider: "salesforce",
          outcome: "failed",
          reason: "failed",
          created_at: "2026-11-10T08:00:00Z",
          failure_reason: "A required CRM property is missing.",
        },
      ],
    };
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );
    assert.dom("tbody tr").exists({ count: 2 });
    assert.dom("tbody tr:first-child").includesText("Skipped");
    assert.dom("tbody tr:first-child a").hasAttribute("href", "/u/jane");
    assert
      .dom("tbody tr:last-child .crm-sync-activity__info")
      .hasAttribute("aria-label", "Details");
    await click("tbody tr:first-child button");
    assert
      .dom(".crm-sync-activity__details")
      .includesText("User already exists as a contact; no lead created");
    assert
      .dom(".crm-sync-activity__configuration a")
      .hasText("Send members as leads");
    assert
      .dom(".crm-sync-activity__configuration a")
      .hasAttribute(
        "href",
        "/admin/plugins/discourse-salesforce/configurations?configuration=12"
      );
    assert.dom(".crm-sync-activity__details").doesNotIncludeText("jane");
    await click("tbody tr:last-child button");
    assert
      .dom("tbody tr:nth-child(2) + .crm-sync-activity__details-row")
      .exists();
    assert.dom(".crm-sync-activity__details-row").exists({ count: 1 });
    assert
      .dom("tbody tr:nth-child(2) button")
      .hasAttribute("aria-expanded", "true");
    assert
      .dom(".crm-sync-activity__configuration")
      .hasText("This sync configuration has been deleted.");
    assert.dom(".crm-sync-activity__configuration a").doesNotExist();
    await click("tbody tr:nth-child(2) button");
    assert.dom(".crm-sync-activity__details-row").doesNotExist();
    assert
      .dom("tbody tr:nth-child(2) button")
      .hasAttribute("aria-expanded", "false");
  });

  test("labels historical providers and keeps disabled providers in the filter", async function (assert) {
    const settings = this.owner.lookup("service:site-settings");
    settings.salesforce_enabled = true;
    settings.hubspot_enabled = false;
    this.model = {
      attempts: ["hubspot", "legacy-crm"].map((provider, id) => ({
        id,
        provider,
        outcome: "failed",
        created_at: "2026-11-11T08:00:00Z",
      })),
    };
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );

    assert
      .dom("tbody tr:first-child td:nth-child(2) > span:last-child")
      .hasText("HubSpot");
    assert
      .dom("tbody tr:last-child td:nth-child(2) > span:last-child")
      .hasText("legacy-crm");
    const filter = selectKit(".crm-sync-activity__provider-filter");
    await filter.expand();
    await filter.selectRowByValue("hubspot");
    assert.strictEqual(filter.header().name(), "HubSpot");
  });

  test("shows the failure reason and rejected email when a failed attempt is expanded", async function (assert) {
    this.model = {
      attempts: [
        {
          id: 1,
          provider: "hubspot",
          outcome: "failed",
          created_at: "2026-11-19T08:00:00Z",
          failure_reason: "HubSpot rejected this email address.",
          rejected_email: "jane@invalid.example",
        },
      ],
    };
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );
    assert
      .dom("tbody")
      .doesNotIncludeText("HubSpot rejected this email address.");
    await click("tbody button");
    assert
      .dom(".crm-sync-activity__details")
      .includesText("HubSpot rejected this email address.");
    assert
      .dom(".crm-sync-activity__details")
      .includesText("jane@invalid.example");
  });

  test("summarizes successful pushes and pulls without a details button", async function (assert) {
    this.model = {
      attempts: [
        {
          id: 5,
          provider: "salesforce",
          object: "Contact",
          reason: "created",
          direction: "outbound",
        },
        {
          id: 4,
          provider: "hubspot",
          object: "contact",
          reason: "created",
          direction: "outbound",
        },
        {
          id: 3,
          provider: "salesforce",
          object: "Lead",
          reason: "updated",
          direction: "outbound",
        },
        {
          id: 2,
          provider: "hubspot",
          object: "contact",
          reason: "imported",
          direction: "inbound",
        },
        {
          id: 1,
          provider: "hubspot",
          object: "contact",
          reason: "unchanged",
          direction: "outbound",
        },
        {
          id: 6,
          username: null,
          configuration: { id: 12, name: "Scheduled contacts" },
          provider: "hubspot",
          reason: "unchanged_summary",
          summary_count: 1200,
          direction: "outbound",
        },
        {
          id: 7,
          username: null,
          provider: "hubspot",
          reason: "missing_companies_summary",
          summary_count: 2,
          direction: "inbound",
        },
      ].map((attempt) => ({
        username: "jane",
        ...attempt,
        outcome: "success",
        created_at: "2026-11-19T08:00:00Z",
      })),
    };
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );
    assert
      .dom("tbody tr:nth-child(1) .crm-sync-activity__reason")
      .hasText("Contact created");
    assert
      .dom("tbody tr:nth-child(2) .crm-sync-activity__reason")
      .hasText("Contact created");
    assert
      .dom("tbody tr:nth-child(3) .crm-sync-activity__reason")
      .hasText("Lead updated");
    assert
      .dom("tbody tr:nth-child(4) .crm-sync-activity__reason")
      .hasText("Contact imported");
    assert
      .dom("tbody tr:nth-child(5) .crm-sync-activity__reason")
      .hasText("Contact already up to date");
    assert
      .dom("tbody tr:first-child .crm-sync-activity__direction")
      .includesText("Push");
    assert
      .dom("tbody tr:first-child .crm-sync-activity__direction > span[title]")
      .hasAttribute("title", "Discourse → CRM");
    assert
      .dom("tbody tr:nth-child(4) .crm-sync-activity__direction")
      .includesText("Pull");
    assert
      .dom("tbody tr:nth-child(4) .crm-sync-activity__direction > span[title]")
      .hasAttribute("title", "CRM → Discourse");
    assert
      .dom("tbody tr:nth-child(6) .crm-sync-activity__reason")
      .hasText("1200 checks found no changes");
    assert.dom("tbody tr:nth-child(6) a").hasText("Scheduled contacts");
    assert
      .dom("tbody tr:last-child .crm-sync-activity__reason")
      .hasText("2 referenced companies were missing");
    assert.dom("tbody button").doesNotExist();
  });

  test("identifies deleted users and configuration-wide attempts", async function (assert) {
    this.model = {
      attempts: [
        { id: 2, user_id: 42 },
        { id: 1, user_id: null },
      ].map((attempt) => ({
        ...attempt,
        provider: "salesforce",
        outcome: "failed",
        created_at: "2026-11-19T08:00:00Z",
      })),
    };
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );
    assert.dom("tbody tr:first-child td:first-child").hasText("Deleted user");
    assert
      .dom("tbody tr:last-child td:first-child")
      .hasText("Configuration-wide");
  });

  test("preserves the clicked row's viewport position when details change", async function (assert) {
    this.model = {
      attempts: [
        {
          id: 1,
          username: "jane",
          provider: "hubspot",
          outcome: "failed",
          reason: "failed",
          created_at: "2026-11-19T08:00:00Z",
        },
      ],
    };
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );
    const row = find("tbody tr");
    const bounds = sinon.stub(row, "getBoundingClientRect");
    bounds.onFirstCall().returns({ top: 300 });
    bounds.returns({ top: 100 });
    const scroll = sinon.stub(window, "scrollBy");
    await click("tbody button");
    assert.true(
      scroll.calledOnceWithExactly({ top: -200, behavior: "instant" })
    );
    assert.dom(".crm-sync-activity__details-row").exists();
  });

  test("keeps loaded rows and pauses automatic loading after a failure", async function (assert) {
    enableLoadMoreObserver();
    const observations = stubIntersectionObserver();
    const attempt = {
      id: 2,
      username: "jane",
      provider: "hubspot",
      outcome: "success",
      reason: "synced",
      created_at: "2026-11-19T08:00:00Z",
    };
    this.model = { attempts: [attempt], next_before: 2 };
    let calls = 0;
    pretender.get("/salesforce/admin/guided-sync/activity.json", () => {
      calls++;
      return calls <= 2
        ? [
            500,
            { "Content-Type": "application/json" },
            JSON.stringify({ errors: ["Unavailable"] }),
          ]
        : [
            200,
            { "Content-Type": "application/json" },
            JSON.stringify({
              attempts: [{ ...attempt, id: 1 }],
              next_before: null,
            }),
          ];
    });
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );
    await click(".crm-sync-activity__filter-button");
    assert.dom(".crm-sync-activity__retry").doesNotExist();
    assert.dom(".crm-sync-activity__load-more").exists();
    await observations
      .findLast(({ element }) =>
        element.matches(".crm-sync-activity__load-more")
      )
      .trigger();
    assert.dom("tbody tr").exists({ count: 1 });
    assert.dom(".crm-sync-activity__load-more").doesNotExist();
    assert.dom(".crm-sync-activity__retry").exists();
    assert.strictEqual(calls, 2);
    await click(".crm-sync-activity__retry");
    assert.dom("tbody tr").exists({ count: 2 });
    assert.dom(".crm-sync-activity__retry").doesNotExist();
    assert.strictEqual(calls, 3);
  });

  test("a submitted filter supersedes an in-flight scroll request", async function (assert) {
    enableLoadMoreObserver();
    const observations = stubIntersectionObserver();
    const attempt = {
      id: 2,
      username: "old",
      provider: "hubspot",
      outcome: "success",
      reason: "synced",
      created_at: "2026-11-19T08:00:00Z",
    };
    this.model = { attempts: [attempt], next_before: 2 };
    const requests = [];
    pretender.get(
      "/salesforce/admin/guided-sync/activity.json",
      (request) => {
        requests.push(request);
        return [
          200,
          { "Content-Type": "application/json" },
          JSON.stringify({
            attempts: [
              {
                ...attempt,
                id: 1,
                username: request.queryParams.before ? "older" : "filtered",
              },
            ],
            next_before: null,
          }),
        ];
      },
      true
    );
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );
    await fillIn('[name="from"]', "2026-11-19");
    const scroll = observations
      .findLast(({ element }) =>
        element.matches(".crm-sync-activity__load-more")
      )
      .trigger();
    await waitUntil(() => requests.length === 1);
    find(".crm-sync-activity__filter-button").click();
    await waitUntil(() => requests.length === 2);
    assert.strictEqual(requests[1].queryParams.from, "2026-11-19");
    pretender.resolve(requests[1]);
    await waitUntil(() => find("tbody").textContent.includes("filtered"));
    pretender.resolve(requests[0]);
    await scroll;
    assert.dom("tbody tr").exists({ count: 1 });
    assert.dom("tbody").includesText("filtered");
  });

  test("scrolling appends older attempts with the applied filters and stops at the last page", async function (assert) {
    enableLoadMoreObserver();
    const observations = stubIntersectionObserver();
    this.model = { attempts: [], next_before: null };
    let calls = 0;
    pretender.get("/salesforce/admin/guided-sync/activity.json", (request) => {
      calls++;
      assert.strictEqual(request.queryParams.username, "jane");
      assert.strictEqual(request.queryParams.outcome, "failed");
      assert.strictEqual(request.queryParams.provider, "salesforce");
      assert.strictEqual(request.queryParams.from, "2026-11-10");
      assert.strictEqual(request.queryParams.to, "2026-11-11");
      assert.strictEqual(
        request.queryParams.timezone,
        Intl.DateTimeFormat().resolvedOptions().timeZone
      );
      const id = calls === 1 ? 2 : 1;
      assert.strictEqual(
        request.queryParams.before,
        calls === 2 ? "2" : undefined
      );
      return [
        200,
        { "Content-Type": "application/json" },
        JSON.stringify({
          attempts: [
            {
              id,
              username: "jane",
              provider: "salesforce",
              outcome: "failed",
              reason: "failed",
              created_at: "2026-11-11T08:00:00Z",
            },
          ],
          next_before: calls === 1 ? 2 : null,
        }),
      ];
    });
    await render(
      <template><CrmSyncActivity @model={{this.model}} /></template>
    );
    pretender.get("/u/search/users", () => [
      200,
      { "Content-Type": "application/json" },
      JSON.stringify({
        users: [
          {
            username: "jane",
            name: "Jane",
            avatar_template: "/letter_avatar/jane/{size}/1.png",
          },
        ],
      }),
    ]);
    const chooser = selectKit(".crm-sync-activity__user");
    await chooser.expand();
    await chooser.fillInFilter("jane");
    await chooser.selectRowByValue("jane");
    assert.strictEqual(chooser.header().name(), "jane");
    const outcome = selectKit(".crm-sync-activity__outcome-filter");
    const provider = selectKit(".crm-sync-activity__provider-filter");
    assert.strictEqual(outcome.header().name(), "All");
    assert.strictEqual(provider.header().name(), "All");
    await outcome.expand();
    await outcome.selectRowByValue("failed");
    await provider.expand();
    await provider.selectRowByValue("salesforce");
    await fillIn('[name="from"]', "2026-11-10");
    await fillIn('[name="to"]', "2026-11-11");
    await click('button[type="submit"]');
    await chooser.expand();
    await chooser.deselectItemByValue("jane");
    await chooser.collapse();
    await observations
      .findLast(({ element }) =>
        element.matches(".crm-sync-activity__load-more")
      )
      .trigger();
    assert.dom("tbody tr").exists({ count: 2 });
    assert.strictEqual(calls, 2);
    assert.dom(".crm-sync-activity__load-more").doesNotExist();
  });
});
