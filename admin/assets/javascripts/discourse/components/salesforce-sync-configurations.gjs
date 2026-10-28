import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AdminConfigAreaCard from "discourse/admin/components/admin-config-area-card";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq, not } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";
import SalesforceDeleteSyncConfirmation from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-delete-sync-confirmation";
import SalesforceGuidedSync from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-guided-sync";
import { createSyncConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

export default class SalesforceSyncConfigurations extends Component {
  @service a11y;
  @service dialog;
  @service toasts;

  @tracked deletingId;
  @tracked records = this.args.records || [];
  @tracked selected;

  constructor() {
    super(...arguments);
    const record = this.records.find(
      (configuration) => configuration.id === this.args.selectedId
    );
    if (record && record.kind !== "posts") {
      this.selected = { key: record.id, configuration: record };
    } else if (this.args.selectedId === "new-users") {
      this.add();
    }
  }

  get editors() {
    return this.selected ? [this.selected] : [];
  }

  get displayRecords() {
    return this.records.map((record) => ({
      ...record,
      statusLabel: i18n(
        `salesforce.guided_sync.${record.sync_status?.error ? "sync_error" : record.active ? "sync_active" : "sync_inactive"}`
      ),
      scope:
        record.kind === "posts"
          ? record.category
          : (record.groups || [record.group]).join(", "),
      kindLabel: i18n(
        `salesforce.guided_sync.${record.kind === "posts" ? "posts_kind" : "users_kind"}`
      ),
    }));
  }

  @action
  add() {
    if (this.args.onSelect && this.args.selectedId !== "new-users") {
      this.args.onSelect("new-users");
      return;
    }
    this.selected = {
      key: "new-users",
      configuration: {
        ...createSyncConfiguration(),
        kind: "users",
        name: i18n("salesforce.guided_sync.default_users_name"),
      },
    };
  }

  @action
  edit(record) {
    if (record.kind === "posts") {
      return;
    }
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
      this.toasts.success({
        duration: "short",
        data: { message: i18n("salesforce.guided_sync.save_success") },
      });
      this.close();
      return true;
    } catch (error) {
      popupAjaxError(error);
      return false;
    }
  }

  <template>
    {{#if (not @credentialsConfigured)}}
      <AdminConfigAreaCard @heading="salesforce.guided_sync.credentials_title">
        <:content>
          <p data-test-credentials-required>{{i18n
              "salesforce.guided_sync.credentials_required"
            }}</p>
          <DButton
            class="btn-primary"
            @href="/admin/plugins/discourse-salesforce/settings"
            @label="salesforce.guided_sync.open_settings"
          />
        </:content>
      </AdminConfigAreaCard>
    {{else if this.selected}}
      {{#each this.editors key="key" as |editor|}}
        <SalesforceGuidedSync
          @groups={{@groups}}
          @record={{editor.configuration}}
          @onCancel={{this.close}}
          @onSave={{this.save}}
        />
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

        <div class="salesforce-sync-configurations__choices">
          <AdminConfigAreaCard
            @heading="salesforce.guided_sync.sync_users"
            @description="salesforce.guided_sync.users_description"
          >
            <:content><DButton
                class="btn-primary"
                data-test-sync-users
                @action={{this.add}}
                @icon="users"
                @label="salesforce.guided_sync.sync_users"
              /></:content>
          </AdminConfigAreaCard>
          <AdminConfigAreaCard
            class="salesforce-sync-configurations__coming-soon"
            @heading="salesforce.guided_sync.sync_posts"
            @description="salesforce.guided_sync.posts_description"
          >
            <:content><DButton
                class="btn-primary"
                data-test-sync-posts
                @disabled={{true}}
                @icon="comments"
                @label="salesforce.guided_sync.posts_coming_soon"
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
                    >{{record.name}}</strong><div
                      class="salesforce-sync-configurations__status"
                    >{{record.statusLabel}}</div></td>
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
                        @disabled={{eq record.kind "posts"}}
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
