import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AdminConfigAreaCard from "discourse/admin/components/admin-config-area-card";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq, not, or } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";
import HubspotSyncConfiguration from "discourse/plugins/discourse-salesforce/discourse/components/hubspot-sync-configuration";
import SalesforceDeleteSyncConfirmation from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-delete-sync-confirmation";
import SalesforceSyncConfiguration from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-sync-configuration";
import {
  createHubspotSyncConfiguration,
  createSyncConfiguration,
} from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const NEW_KEYS = {
  salesforce: "new-salesforce-users",
  hubspot: "new-hubspot-users",
};

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
      (configuration) =>
        String(configuration.id) === String(this.args.selectedId)
    );
    const provider = Object.keys(NEW_KEYS).find(
      (name) => NEW_KEYS[name] === this.args.selectedId
    );
    if (record && record.kind !== "posts") {
      this.selected = { key: record.id, configuration: record };
    } else if (provider) {
      this.add(provider);
    }
  }

  get editors() {
    return this.selected ? [this.selected] : [];
  }

  get providers() {
    return this.args.providers || [];
  }

  get salesforceProvider() {
    return this.providers.find((provider) => provider.name === "salesforce");
  }

  get hubspotProvider() {
    return this.providers.find((provider) => provider.name === "hubspot");
  }

  get credentialsConfigured() {
    return this.providers.some((provider) => provider.credentials_configured);
  }

  get hubspotConfigured() {
    return this.records.some(
      (record) =>
        record.provider === "hubspot" && record.direction === "inbound"
    );
  }

  get displayRecords() {
    return this.records.map((record) => ({
      ...record,
      scope:
        record.kind === "posts"
          ? record.category
          : record.direction === "inbound"
            ? i18n("salesforce.guided_sync.all_users")
            : (record.groups || []).join(", "),
      objectLabel:
        record.provider === "hubspot"
          ? i18n("salesforce.guided_sync.hubspot.contacts")
          : record.object,
      typeLabel: i18n(
        `salesforce.guided_sync.types.${record.direction}_${record.kind}`
      ),
    }));
  }

  @action
  add(provider) {
    const key = NEW_KEYS[provider];
    if (this.args.onSelect && this.args.selectedId !== key) {
      this.args.onSelect(key);
      return;
    }
    this.selected = {
      key,
      configuration:
        provider === "hubspot"
          ? {
              ...createHubspotSyncConfiguration(),
              name: i18n("salesforce.guided_sync.hubspot.default_name"),
            }
          : {
              ...createSyncConfiguration(),
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
    {{#if (not this.credentialsConfigured)}}
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
        {{#if (eq editor.configuration.provider "hubspot")}}
          <HubspotSyncConfiguration
            @record={{editor.configuration}}
            @onCancel={{this.close}}
            @onSave={{this.save}}
          />
        {{else}}
          <SalesforceSyncConfiguration
            @groups={{@groups}}
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

        <div class="salesforce-sync-configurations__choices">
          <AdminConfigAreaCard
            @heading="salesforce.guided_sync.send_users"
            @description="salesforce.guided_sync.users_description"
          >
            <:content><DButton
                class="btn-primary"
                data-test-sync-users
                @action={{fn this.add "salesforce"}}
                @disabled={{not this.salesforceProvider.credentials_configured}}
                @icon="users"
                @label="salesforce.guided_sync.send_users"
              /></:content>
          </AdminConfigAreaCard>
          {{#if this.hubspotProvider}}
            <AdminConfigAreaCard
              @heading="salesforce.guided_sync.hubspot.pull_contacts"
              @description="salesforce.guided_sync.hubspot.description"
            >
              <:content><DButton
                  class="btn-primary"
                  data-test-sync-contacts
                  @action={{fn this.add "hubspot"}}
                  @disabled={{or
                    (not this.hubspotProvider.credentials_configured)
                    this.hubspotConfigured
                  }}
                  @icon="address-card"
                  @label={{if
                    this.hubspotConfigured
                    "salesforce.guided_sync.hubspot.already_configured"
                    "salesforce.guided_sync.hubspot.pull_contacts"
                  }}
                /></:content>
            </AdminConfigAreaCard>
          {{/if}}
          <AdminConfigAreaCard
            class="salesforce-sync-configurations__coming-soon"
            @heading="salesforce.guided_sync.send_posts"
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
          <table class="d-table salesforce-sync-configurations__table">
            <thead class="d-table__header"><tr>
                <th>{{i18n "salesforce.guided_sync.configuration_name"}}</th>
                <th>{{i18n "salesforce.guided_sync.configuration_type"}}</th>
                <th>{{i18n "salesforce.guided_sync.crm_object"}}</th>
                <th>{{i18n "salesforce.guided_sync.scope"}}</th>
                <th></th>
              </tr></thead>
            <tbody class="d-table__body">
              {{#each this.displayRecords key="id" as |record|}}
                <tr class="d-table__row" data-test-configuration={{record.id}}>
                  <td class="d-table__cell --overview">
                    <strong>{{record.name}}</strong>
                    {{#if record.connection_changed}}
                      <div class="salesforce-sync-configurations__status">
                        {{i18n "salesforce.guided_sync.connection_changed"}}
                      </div>
                    {{else if record.sync_status.error}}
                      <div class="salesforce-sync-configurations__status">
                        {{i18n "salesforce.guided_sync.sync_error"}}
                      </div>
                    {{/if}}
                  </td>
                  <td class="d-table__cell --detail"><div
                      class="d-table__mobile-label"
                    >{{i18n
                        "salesforce.guided_sync.configuration_type"
                      }}</div>{{record.typeLabel}}</td>
                  <td class="d-table__cell --detail"><div
                      class="d-table__mobile-label"
                    >{{i18n
                        "salesforce.guided_sync.crm_object"
                      }}</div>{{record.objectLabel}}</td>
                  <td
                    class="d-table__cell --detail"
                    data-test-configuration-scope
                  ><div class="d-table__mobile-label">{{i18n
                        "salesforce.guided_sync.scope"
                      }}</div>{{record.scope}}</td>
                  <td class="d-table__cell --controls">
                    <div class="d-table__cell-actions">
                      <DButton
                        class="btn-default btn-small"
                        data-test-configure={{record.id}}
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
