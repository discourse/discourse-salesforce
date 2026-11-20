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
import CrmDeleteSyncConfirmation from "discourse/plugins/discourse-salesforce/discourse/components/crm-delete-sync-confirmation";
import CrmOutboundSyncConfiguration from "discourse/plugins/discourse-salesforce/discourse/components/crm-outbound-sync-configuration";
import CrmSegmentEditor from "discourse/plugins/discourse-salesforce/discourse/components/crm-segment-editor";
import CrmSegments from "discourse/plugins/discourse-salesforce/discourse/components/crm-segments";
import HubspotSyncConfiguration from "discourse/plugins/discourse-salesforce/discourse/components/hubspot-sync-configuration";
import {
  createSegment,
  deleteSegment,
  findSegment,
  saveSegment,
} from "discourse/plugins/discourse-salesforce/discourse/lib/crm-segments";
import {
  createHubspotSyncConfiguration,
  createSyncConfiguration,
  targetLabel,
} from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const FLOWS = {
  outbound: {
    newKey: "new-salesforce-users",
    create: (target) => createSyncConfiguration(target),
  },
  inbound: {
    newKey: "new-hubspot-users",
    create: () => ({
      ...createHubspotSyncConfiguration(),
      name: i18n("salesforce.guided_sync.hubspot.default_name"),
    }),
  },
};
const NEW_SEGMENT_KEY = "new-segment";
const SEGMENT_KEY_PREFIX = "segment-";

export default class CrmSyncConfigurations extends Component {
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
    const direction = Object.keys(FLOWS).find(
      (name) => FLOWS[name].newKey === this.args.selectedId
    );
    const selectedId = String(this.args.selectedId ?? "");
    if (record && record.kind !== "posts") {
      this.selected = this.#editorFor(record);
    } else if (direction) {
      this.add(direction);
    } else if (selectedId === NEW_SEGMENT_KEY) {
      this.selected = this.#segmentEditorFor(createSegment(), NEW_SEGMENT_KEY);
    } else if (selectedId.startsWith(SEGMENT_KEY_PREFIX)) {
      const segment = findSegment(
        selectedId.slice(SEGMENT_KEY_PREFIX.length),
        this.args.groups
      );
      if (segment) {
        this.selected = this.#segmentEditorFor(segment, selectedId);
      }
    }
  }

  get editors() {
    return this.selected ? [this.selected] : [];
  }

  get providers() {
    return this.args.providers || [];
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
      targetLabel: targetLabel(record.provider || "salesforce", record.object),
      scope:
        record.kind === "posts"
          ? record.category
          : record.direction === "inbound"
            ? i18n("salesforce.guided_sync.all_users")
            : (record.groups || []).join(", "),
      typeLabel: i18n(
        `salesforce.guided_sync.types.${record.direction}_${record.kind}`
      ),
    }));
  }

  @action
  add(direction) {
    const { newKey, create } = FLOWS[direction];
    if (this.args.onSelect && this.args.selectedId !== newKey) {
      this.args.onSelect(newKey);
      return;
    }
    this.selected = this.#editorFor(create(this.args.targets?.[0]), newKey);
  }

  @action
  addSegment() {
    if (this.args.onSelect && this.args.selectedId !== NEW_SEGMENT_KEY) {
      this.args.onSelect(NEW_SEGMENT_KEY);
      return;
    }
    this.selected = this.#segmentEditorFor(createSegment(), NEW_SEGMENT_KEY);
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
    this.selected = this.#editorFor(record);
  }

  @action
  editSegment(segment) {
    const key = `${SEGMENT_KEY_PREFIX}${segment.id}`;
    if (this.args.onSelect) {
      this.args.onSelect(key);
      return;
    }
    this.selected = this.#segmentEditorFor(segment, key);
  }

  @action
  async deleteSegment(segment) {
    await deleteSegment(segment.id);
    this.a11y.announce(i18n("salesforce.guided_sync.segments.deleted"));
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
      bodyComponent: CrmDeleteSyncConfirmation,
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

  @action
  async saveSegment(segment) {
    await saveSegment(segment);
    this.toasts.success({
      duration: "short",
      data: { message: i18n("salesforce.guided_sync.segments.saved") },
    });
    this.close();
    return true;
  }

  #editorFor(configuration, key = configuration.id) {
    return {
      key,
      configuration,
      component:
        configuration.direction === "inbound"
          ? HubspotSyncConfiguration
          : CrmOutboundSyncConfiguration,
      onSave: this.save,
    };
  }

  #segmentEditorFor(segment, key) {
    return {
      key,
      configuration: segment,
      component: CrmSegmentEditor,
      onSave: this.saveSegment,
    };
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
        <editor.component
          @groups={{@groups}}
          @targets={{@targets}}
          @record={{editor.configuration}}
          @onCancel={{this.close}}
          @onSave={{editor.onSave}}
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
            @heading="salesforce.guided_sync.send_users"
            @description="salesforce.guided_sync.users_description"
          >
            <:content><DButton
                class="btn-primary"
                data-test-sync-users
                @action={{fn this.add "outbound"}}
                @disabled={{not @targets.length}}
                @icon="users"
                @label="salesforce.guided_sync.send_users"
              /></:content>
          </AdminConfigAreaCard>
          {{#if this.hubspotProvider}}
            <AdminConfigAreaCard
              @heading="salesforce.guided_sync.pull_from_crm"
              @description="salesforce.guided_sync.pull_description"
            >
              <:content><DButton
                  class="btn-primary"
                  data-test-pull-crm
                  @action={{fn this.add "inbound"}}
                  @disabled={{or
                    (not this.hubspotProvider.credentials_configured)
                    this.hubspotConfigured
                  }}
                  @icon="address-card"
                  @label={{if
                    this.hubspotConfigured
                    "salesforce.guided_sync.hubspot.already_configured"
                    "salesforce.guided_sync.pull_from_crm"
                  }}
                /></:content>
            </AdminConfigAreaCard>
          {{/if}}
          <AdminConfigAreaCard
            @heading="salesforce.guided_sync.segments.card_title"
            @description="salesforce.guided_sync.segments.card_description"
          >
            <:content><DButton
                class="btn-primary"
                data-test-define-segment
                @action={{this.addSegment}}
                @icon="filter"
                @label="salesforce.guided_sync.segments.add"
              /></:content>
          </AdminConfigAreaCard>
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
                        {{#if
                          (eq
                            record.sync_status.error "Hubspot::MissingContact"
                          )
                        }}
                          {{i18n
                            "salesforce.guided_sync.hubspot.missing_contact"
                          }}
                        {{else if
                          (eq
                            record.sync_status.error
                            "Hubspot::InvalidPropertyValue"
                          )
                        }}
                          {{i18n
                            "salesforce.guided_sync.hubspot.invalid_property_value"
                          }}
                        {{else if
                          (eq
                            record.sync_status.error
                            "Hubspot::DailyQuotaExceeded"
                          )
                        }}
                          {{i18n
                            "salesforce.guided_sync.hubspot.daily_quota_exceeded"
                          }}
                        {{else if (eq record.direction "outbound")}}
                          {{i18n "salesforce.guided_sync.outbound_sync_error"}}
                        {{else}}
                          {{i18n "salesforce.guided_sync.sync_error"}}
                        {{/if}}
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
                      }}</div>{{record.targetLabel}}</td>
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
        <CrmSegments
          @groups={{@groups}}
          @onAdd={{this.addSegment}}
          @onDelete={{this.deleteSegment}}
          @onEdit={{this.editSegment}}
        />
      </div>
    {{/if}}
  </template>
}
