import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { schedule } from "@ember/runloop";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { longDate } from "discourse/lib/formatter";
import getURL from "discourse/lib/get-url";
import ComboBox from "discourse/select-kit/components/combo-box";
import UserChooser from "discourse/select-kit/components/user-chooser";
import { eq } from "discourse/truth-helpers";
import DLoadMore from "discourse/ui-kit/d-load-more";
import DUserLink from "discourse/ui-kit/d-user-link";
import { i18n } from "discourse-i18n";
import {
  providerLabel,
  providerOptions,
} from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

export default class CrmSyncActivity extends Component {
  @tracked result = null;
  @tracked loading = false;
  @tracked selected = null;
  @tracked loadMoreFailed = false;

  @tracked username = "";
  @tracked outcome = null;
  @tracked provider = null;

  from = "";
  to = "";
  appliedFilters = {};
  latestRequestId = 0;

  reason = (attempt) => {
    if (attempt.outcome === "failed") {
      return attempt.failure_reason;
    }
    if (attempt.summary_count) {
      return i18n(`salesforce.activity.reasons.${attempt.reason}`, {
        count: attempt.summary_count,
      });
    }
    const objectKey =
      { contact: "contact", lead: "lead" }[attempt.object?.toLowerCase()] ||
      "record";
    return i18n(`salesforce.activity.reasons.${attempt.reason}`, {
      object: i18n(`salesforce.activity.objects.${objectKey}`),
    });
  };

  outcomeLabel = (attempt) =>
    i18n(`salesforce.activity.outcomes.${attempt.outcome}`);

  configurationUrl = (configuration) =>
    getURL(
      `/admin/plugins/discourse-salesforce/configurations?configuration=${configuration.id}`
    );

  get selectedUsernames() {
    return this.username ? [this.username] : [];
  }

  @action
  selectUser(usernames) {
    this.username = usernames[0] || "";
  }

  get outcomes() {
    return ["success", "failed", "skipped"].map((id) => ({
      id,
      name: i18n(`salesforce.activity.outcomes.${id}`),
    }));
  }

  @action
  selectOutcome(value) {
    this.outcome = value;
  }

  @action
  selectProvider(value) {
    this.provider = value;
  }

  get attempts() {
    return (this.result ?? this.args.model).attempts;
  }

  get nextBefore() {
    return (this.result ?? this.args.model).next_before;
  }

  @action
  changeFilter(event) {
    this[event.target.name] = event.target.value;
  }

  async load(before) {
    const requestId = ++this.latestRequestId;
    this.loading = true;
    try {
      const filters = before
        ? this.appliedFilters
        : {
            outcome: this.outcome,
            provider: this.provider,
            username: this.username,
            from: this.from || undefined,
            to: this.to || undefined,
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
          };
      const result = await ajax("/salesforce/admin/guided-sync/activity.json", {
        data: {
          ...filters,
          before,
        },
      });
      if (requestId !== this.latestRequestId) {
        return;
      }
      this.loadMoreFailed = false;
      this.appliedFilters = filters;
      this.result = {
        ...result,
        attempts: before
          ? [...this.attempts, ...result.attempts]
          : result.attempts,
      };
      if (!before) {
        this.selected = null;
      }
    } catch (error) {
      if (requestId !== this.latestRequestId) {
        return;
      }
      if (before) {
        this.loadMoreFailed = true;
      }
      popupAjaxError(error);
    } finally {
      if (requestId === this.latestRequestId) {
        this.loading = false;
      }
    }
  }

  @action
  filter(event) {
    event.preventDefault();
    return this.load();
  }

  @action
  loadMore() {
    if (!this.nextBefore || this.loading) {
      return;
    }
    return this.load(this.nextBefore);
  }

  @action
  inspect(attempt, event) {
    const row = event.target.closest("tr");
    const top = row.getBoundingClientRect().top;
    this.selected = this.selected?.id === attempt.id ? null : attempt;
    schedule("afterRender", () => {
      if (!row.isConnected) {
        return;
      }
      const offset = row.getBoundingClientRect().top - top;
      if (offset) {
        window.scrollBy({ top: offset, behavior: "instant" });
      }
    });
  }

  <template>
    <section class="crm-sync-activity">
      <h2>{{i18n "salesforce.activity.title"}}</h2>
      <form class="crm-sync-activity__filters" {{on "submit" this.filter}}>
        <label>
          {{i18n "salesforce.activity.outcome"}}
          <ComboBox
            class="crm-sync-activity__outcome-filter"
            @content={{this.outcomes}}
            @value={{this.outcome}}
            @onChange={{this.selectOutcome}}
            @options={{hash
              none="salesforce.activity.all"
              autoInsertNoneItem=true
              filterable=false
            }}
          />
        </label>
        <label>
          {{i18n "salesforce.activity.provider"}}
          <ComboBox
            class="crm-sync-activity__provider-filter"
            @content={{providerOptions}}
            @value={{this.provider}}
            @onChange={{this.selectProvider}}
            @options={{hash
              none="salesforce.activity.all"
              autoInsertNoneItem=true
              filterable=false
            }}
          />
        </label>
        <label class="crm-sync-activity__user-filter">
          {{i18n "salesforce.activity.user"}}
          <UserChooser
            class="crm-sync-activity__user"
            @value={{this.selectedUsernames}}
            @onChange={{this.selectUser}}
            @includeStagedUsers={{true}}
            @options={{hash maximum=1 excludeCurrentUser=false}}
          />
        </label>
        <label>
          {{i18n "salesforce.activity.from"}}
          <input name="from" type="date" {{on "input" this.changeFilter}} />
        </label>
        <label>
          {{i18n "salesforce.activity.to"}}
          <input name="to" type="date" {{on "input" this.changeFilter}} />
        </label>
        <DButton
          class="btn-primary crm-sync-activity__filter-button"
          @type="submit"
          @label="salesforce.activity.filter"
        />
      </form>
      <table class="d-table crm-sync-activity__table">
        <thead class="d-table__header">
          <tr class="d-table__row">
            <th class="d-table__header-cell" scope="col">{{i18n
                "salesforce.activity.user"
              }}</th>
            <th class="d-table__header-cell" scope="col">{{i18n
                "salesforce.activity.provider"
              }}</th>
            <th class="d-table__header-cell" scope="col">{{i18n
                "salesforce.activity.direction"
              }}</th>
            <th class="d-table__header-cell" scope="col">{{i18n
                "salesforce.activity.time"
              }}</th>
            <th class="d-table__header-cell" scope="col">{{i18n
                "salesforce.activity.outcome"
              }}</th>
          </tr>
        </thead>
        <tbody class="d-table__body">
          {{#each this.attempts key="id" as |attempt|}}
            <tr class="d-table__row crm-sync-activity__attempt">
              <td class="d-table__cell --overview">{{#if
                  attempt.username
                }}<DUserLink
                    @username={{attempt.username}}
                  >{{attempt.username}}</DUserLink>{{else if
                  attempt.summary_count
                }}
                  {{#if attempt.configuration}}
                    <a
                      href={{this.configurationUrl attempt.configuration}}
                    >{{attempt.configuration.name}}</a>
                  {{else}}
                    {{i18n "salesforce.activity.deleted_configuration"}}
                  {{/if}}
                {{else if attempt.user_id}}{{i18n
                    "salesforce.activity.deleted_user"
                  }}{{else}}{{i18n
                    "salesforce.activity.configuration_wide"
                  }}{{/if}}</td>
              <td class="d-table__cell --detail">
                <span class="d-table__mobile-label">{{i18n
                    "salesforce.activity.provider"
                  }}</span>
                <span>{{providerLabel attempt.provider}}</span></td>
              <td class="d-table__cell --detail crm-sync-activity__direction">
                <span class="d-table__mobile-label">{{i18n
                    "salesforce.activity.direction"
                  }}</span>

                {{#if (eq attempt.direction "inbound")}}
                  <span
                    title={{i18n "salesforce.activity.pull_description"}}
                  ><span aria-hidden="true">↓</span>
                    {{i18n "salesforce.activity.pull"}}</span>
                {{else if (eq attempt.direction "outbound")}}
                  <span
                    title={{i18n "salesforce.activity.push_description"}}
                  ><span aria-hidden="true">↑</span>
                    {{i18n "salesforce.activity.push"}}</span>
                {{/if}}
              </td>
              <td class="d-table__cell --detail">
                <span class="d-table__mobile-label">{{i18n
                    "salesforce.activity.time"
                  }}</span>
                <time datetime={{attempt.created_at}}>{{longDate
                    attempt.created_at
                  }}</time></td>
              <td class="d-table__cell --detail">
                <span class="d-table__mobile-label">{{i18n
                    "salesforce.activity.outcome"
                  }}</span>
                <div><span
                    class="crm-sync-activity__outcome"
                    data-outcome={{attempt.outcome}}
                  >{{this.outcomeLabel attempt}}</span>
                  {{#if (eq attempt.outcome "success")}}
                    <div class="crm-sync-activity__reason">{{this.reason
                        attempt
                      }}</div>
                  {{/if}}
                  {{#unless (eq attempt.outcome "success")}}
                    <DButton
                      class="btn-transparent crm-sync-activity__info"
                      aria-label={{i18n "salesforce.activity.details"}}
                      aria-expanded={{if
                        (eq this.selected.id attempt.id)
                        "true"
                        "false"
                      }}
                      aria-controls="crm-sync-details-{{attempt.id}}"
                      @action={{this.inspect}}
                      @actionParam={{attempt}}
                      @forwardEvent={{true}}
                      @icon="circle-info"
                      @title="salesforce.activity.details"
                    />
                  {{/unless}}
                </div>
              </td>
            </tr>
            {{#if (eq this.selected.id attempt.id)}}
              <tr class="d-table__row crm-sync-activity__details-row">
                <td class="d-table__cell" colspan="5">
                  <section
                    class="crm-sync-activity__details"
                    id="crm-sync-details-{{attempt.id}}"
                    aria-live="polite"
                  >
                    <p>{{#if (eq this.selected.outcome "failed")}}<strong>{{i18n
                            "salesforce.activity.error"
                          }}:</strong>
                      {{/if}}{{this.reason this.selected}}</p>
                    {{#if this.selected.rejected_email}}
                      <p>
                        <strong>{{i18n
                            "salesforce.activity.rejected_email"
                          }}:</strong>
                        {{this.selected.rejected_email}}
                      </p>
                    {{/if}}
                    <p class="crm-sync-activity__configuration">
                      {{#if this.selected.configuration}}
                        <strong>{{i18n
                            "salesforce.activity.configuration"
                          }}:</strong>
                        <a
                          href={{this.configurationUrl
                            this.selected.configuration
                          }}
                        >{{this.selected.configuration.name}}</a>
                      {{else}}
                        {{i18n "salesforce.activity.deleted_configuration"}}
                      {{/if}}
                    </p>
                  </section>
                </td>
              </tr>
            {{/if}}
          {{else}}
            <tr class="d-table__row"><td
                class="d-table__cell"
                colspan="5"
              >{{i18n "salesforce.activity.empty"}}</td></tr>
          {{/each}}
        </tbody>
      </table>
      {{#if this.loading}}
        <p role="status">{{i18n "loading"}}</p>
      {{/if}}
      {{#if this.nextBefore}}
        {{#if this.loadMoreFailed}}
          <DButton
            class="crm-sync-activity__retry"
            @action={{this.loadMore}}
            @label="salesforce.activity.retry"
          />
        {{else}}
          <DLoadMore
            class="crm-sync-activity__load-more"
            @action={{this.loadMore}}
            @isLoading={{this.loading}}
            @rootMargin="200px"
          />
        {{/if}}
      {{/if}}

    </section>
  </template>
}
