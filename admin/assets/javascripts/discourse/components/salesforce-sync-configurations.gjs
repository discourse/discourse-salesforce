import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AdminConfigAreaCard from "discourse/admin/components/admin-config-area-card";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";
import SalesforceCaseSync from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-case-sync";
import SalesforceConnectionSummary from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-connection-summary";
import SalesforceDeleteSyncConfirmation from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-delete-sync-confirmation";
import SalesforceGuidedSync from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-guided-sync";
import { createCaseDemoConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/guided-case-sync-demo";
import { createDemoConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-demo";

export default class SalesforceSyncConfigurations extends Component {
  @service a11y;
  @service dialog;
  @service toasts;

  @tracked deletingId;
  @tracked records = this.args.records || [];
  @tracked selected;
  @tracked _connection;

  constructor() {
    super(...arguments);
    const record = this.records.find(
      (configuration) => configuration.id === this.args.selectedId
    );
    if (record) {
      this.selected = { key: record.id, configuration: record };
    } else if (["new-users", "new-posts"].includes(this.args.selectedId)) {
      this.add(this.args.selectedId.slice(4));
    }
  }

  get connection() {
    return this._connection || this.args.connection;
  }

  get editors() {
    return this.selected ? [this.selected] : [];
  }

  get displayRecords() {
    return this.records.map((record) => ({
      ...record,
      scope: record.kind === "posts" ? record.category : record.group,
      kindLabel: i18n(
        `salesforce.guided_sync.${record.kind === "posts" ? "posts_kind" : "users_kind"}`
      ),
    }));
  }

  @action
  add(kind) {
    if (this.args.onSelect && this.args.selectedId !== `new-${kind}`) {
      this.args.onSelect(`new-${kind}`);
      return;
    }
    this.selected = {
      key: `new-${kind}`,
      configuration:
        kind === "posts"
          ? {
              ...createCaseDemoConfiguration(),
              name: i18n("salesforce.guided_sync.cases.default_name"),
            }
          : {
              ...createDemoConfiguration(),
              kind: "users",
              name: i18n("salesforce.guided_sync.default_users_name"),
            },
    };
  }

  @action
  edit(record) {
    if (this.args.onSelect) {
      this.args.onSelect(record.id);
      return;
    }
    this.selected = { key: record.id, configuration: record };
  }

  @action
  close() {
    this.selected = null;
    this.args.onClose?.();
  }

  @action
  deleteConfiguration(record) {
    this.dialog.deleteConfirm({
      title: i18n("salesforce.guided_sync.delete_title"),
      bodyComponent: SalesforceDeleteSyncConfirmation,
      bodyComponentModel: record,
      confirmButtonLabel: "salesforce.guided_sync.delete_configuration",
      didConfirm: async () => {
        this.deletingId = record.id;
        try {
          await ajax(
            `/salesforce/admin/guided-sync/configurations/${record.id}.json`,
            { type: "DELETE" }
          );
          this.records = this.records.filter(
            (configuration) => configuration.id !== record.id
          );
          this.a11y.announce(i18n("salesforce.guided_sync.deleted_message"));
        } catch (error) {
          popupAjaxError(error);
        } finally {
          this.deletingId = null;
        }
      },
    });
  }

  @action
  async connect(environment) {
    try {
      const result = await ajax(
        "/salesforce/admin/guided-sync/connection.json",
        {
          type: "PUT",
          data: { environment },
        }
      );
      this._connection = result.connection;
      return true;
    } catch (error) {
      popupAjaxError(error);
      return false;
    }
  }

  @action
  async save(configuration) {
    try {
      const id = this.selected.configuration.id;
      const result = await ajax(
        `/salesforce/admin/guided-sync/configurations${id ? `/${id}` : ""}.json`,
        {
          type: id ? "PUT" : "POST",
          contentType: "application/json",
          data: JSON.stringify({ configuration }),
        }
      );
      this.records = [
        ...this.records.filter(
          (record) => record.id !== result.configuration.id
        ),
        result.configuration,
      ];
      this.selected = { ...this.selected, configuration: result.configuration };
      this.toasts.success({
        duration: "short",
        data: { message: i18n("salesforce.guided_sync.save_success") },
      });
      return true;
    } catch (error) {
      popupAjaxError(error);
      return false;
    }
  }

  <template>
    {{#if this.selected}}
      {{#each this.editors key="key" as |editor|}}
        {{#if (eq editor.configuration.kind "posts")}}
          <SalesforceCaseSync
            @connection={{this.connection}}
            @onConnect={{this.connect}}
            @record={{editor.configuration}}
            @onCancel={{this.close}}
            @onSave={{this.save}}
          />
        {{else}}
          <SalesforceGuidedSync
            @connection={{this.connection}}
            @onConnect={{this.connect}}
            @record={{editor.configuration}}
            @onCancel={{this.close}}
            @onSave={{this.save}}
          />
        {{/if}}
      {{/each}}
    {{else}}
      <div
        class="salesforce-sync-configurations admin-config-page__main-area"
        ...attributes
      >
        <DPageSubheader
          @titleLabel={{i18n "salesforce.guided_sync.configurations_title"}}
          @descriptionLabel={{i18n
            "salesforce.guided_sync.configurations_description"
          }}
        />

        {{#if this.connection}}
          <SalesforceConnectionSummary
            @connected={{true}}
            @environment={{this.connection.environment}}
          />
        {{/if}}
        <div class="salesforce-sync-configurations__choices">
          <AdminConfigAreaCard
            @heading="salesforce.guided_sync.sync_users"
            @description="salesforce.guided_sync.users_description"
          >
            <:content><DButton
                class="btn-primary"
                data-test-sync-users
                @action={{fn this.add "users"}}
                @icon="users"
                @label="salesforce.guided_sync.sync_users"
              /></:content>
          </AdminConfigAreaCard>
          <AdminConfigAreaCard
            @heading="salesforce.guided_sync.sync_posts"
            @description="salesforce.guided_sync.posts_description"
          >
            <:content><DButton
                class="btn-primary"
                data-test-sync-posts
                @action={{fn this.add "posts"}}
                @icon="comments"
                @label="salesforce.guided_sync.sync_posts"
              /></:content>
          </AdminConfigAreaCard>
        </div>
        {{#if this.records.length}}
          <table class="d-table">
            <thead class="d-table__header"><tr>
                <th>{{i18n "salesforce.guided_sync.configuration_name"}}</th>
                <th>{{i18n "salesforce.guided_sync.sync_type"}}</th>
                <th>{{i18n "salesforce.guided_sync.salesforce_object"}}</th>
                <th>{{i18n "salesforce.guided_sync.scope"}}</th>
                <th></th>
              </tr></thead>
            <tbody class="d-table__body">
              {{#each this.displayRecords key="id" as |record|}}
                <tr class="d-table__row" data-test-configuration={{record.id}}>
                  <td class="d-table__cell --overview"><strong
                    >{{record.name}}</strong></td>
                  <td class="d-table__cell --detail"><div
                      class="d-table__mobile-label"
                    >{{i18n
                        "salesforce.guided_sync.sync_type"
                      }}</div>{{record.kindLabel}}</td>
                  <td class="d-table__cell --detail"><div
                      class="d-table__mobile-label"
                    >{{i18n
                        "salesforce.guided_sync.salesforce_object"
                      }}</div>{{record.object}}</td>
                  <td class="d-table__cell --detail"><div
                      class="d-table__mobile-label"
                    >{{i18n
                        "salesforce.guided_sync.scope"
                      }}</div>{{record.scope}}</td>
                  <td class="d-table__cell --controls">
                    <div class="d-table__cell-actions">
                      <DButton
                        class="btn-default btn-small"
                        @action={{fn this.edit record}}
                        @label="salesforce.guided_sync.configure"
                      />
                      <DButton
                        class="btn-danger btn-small"
                        data-test-delete-configuration={{record.id}}
                        @action={{fn this.deleteConfiguration record}}
                        @disabled={{eq this.deletingId record.id}}
                        @icon="trash-can"
                        @label="salesforce.guided_sync.delete_configuration"
                      />
                    </div>
                  </td>
                </tr>
              {{/each}}
            </tbody>
          </table>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
