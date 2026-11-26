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
  saveSegment,
  segmentForm,
  segmentPayload,
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
  @tracked segments = this.args.segments || [];
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
    } else if (selectedId === NEW_SEGMENT_KEY && this.canDefineSegments) {
      this.selected = this.#segmentEditorFor(
        createSegment(this.args.segmentConfigurations[0].id),
        NEW_SEGMENT_KEY
      );
    } else if (selectedId.startsWith(SEGMENT_KEY_PREFIX)) {
      const segment = this.segments.find(
        (item) =>
          String(item.id) === selectedId.slice(SEGMENT_KEY_PREFIX.length)
      );
      if (segment) {
        this.selected = this.#segmentEditorFor(
          segmentForm(segment),
          selectedId
        );
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

  get segmentsEnabled() {
    return this.args.segments !== undefined;
  }

  get canDefineSegments() {
    return this.args.segmentConfigurations?.length > 0;
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
    this.selected = this.#segmentEditorFor(
      createSegment(this.args.segmentConfigurations[0].id),
      NEW_SEGMENT_KEY
    );
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
    this.selected = this.#segmentEditorFor(segmentForm(segment), key);
  }

  @action
  async deleteSegment(segment) {
    try {
      await deleteSegment(segment.id);
      this.segments = this.segments.filter((item) => item.id !== segment.id);
      this.a11y.announce(i18n("salesforce.guided_sync.segments.deleted"));
    } catch (error) {
      popupAjaxError(error);
    }
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
  async saveSegment(form) {
    try {
      const segment = await saveSegment(
        this.selected.configuration.id,
        segmentPayload(form)
      );
      this.segments = [
        ...this.segments.filter((item) => item.id !== segment.id),
        segment,
      ].sort((a, b) => a.id - b.id);
      this.toasts.success({
        duration: "short",
        data: { message: i18n("salesforce.guided_sync.segments.saved") },
      });
      this.close();
      return true;
    } catch (error) {
      popupAjaxError(error);
      return false;
    }
  }

  #editorFor(configuration, key = configuration.id) {
    return {
      key,
      configuration,
      component:
        configuration.direction === "inbound"
          ? HubspotSyncConfiguration
          : CrmOutboundSyncConfiguration,
      groups: this.args.groups,
      onSave: this.save,
    };
  }

  #segmentEditorFor(segment, key) {
    return {
      key,
      configuration: segment,
      component: CrmSegmentEditor,
      configurations: this.args.segmentConfigurations,
      groups: this.args.segmentGroups,
      properties: this.args.segmentProperties,
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
          @configurations={{editor.configurations}}
          @groups={{editor.groups}}
          @properties={{editor.properties}}
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
          {{#if this.segmentsEnabled}}
            <AdminConfigAreaCard
              @heading="salesforce.guided_sync.segments.card_title"
              @description="salesforce.guided_sync.segments.card_description"
            >
              <:content><DButton
                  class="btn-primary"
                  data-test-define-segment
                  @action={{this.addSegment}}
                  @disabled={{not this.canDefineSegments}}
                  @icon="filter"
                  @label="salesforce.guided_sync.segments.add"
                  @title={{unless
                    this.canDefineSegments
                    "salesforce.guided_sync.segments.requires_pull"
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
        {{#if this.segmentsEnabled}}
          <CrmSegments
            @configurations={{@segmentConfigurations}}
            @properties={{@segmentProperties}}
            @segments={{this.segments}}
            @onAdd={{if this.canDefineSegments this.addSegment}}
            @onDelete={{this.deleteSegment}}
            @onEdit={{this.editSegment}}
          />
        {{/if}}
      </div>
    {{/if}}
  </template>
}
