import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { cancel, next } from "@ember/runloop";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DMultiSelect from "discourse/ui-kit/d-multi-select";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import CrmCreateGroupModal from "discourse/plugins/discourse-salesforce/discourse/components/crm-create-group-modal";
import CrmFieldMenu from "discourse/plugins/discourse-salesforce/discourse/components/crm-field-menu";
import CrmSourceMenu from "discourse/plugins/discourse-salesforce/discourse/components/crm-source-menu";
import SyncConfigurationHeading from "discourse/plugins/discourse-salesforce/discourse/components/sync-configuration-heading";
import {
  createSyncConfiguration,
  outboundTarget,
  targetLabel,
  updateMapping,
  USER_SYNC_SOURCES,
} from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PREFIX = "salesforce.guided_sync";
const MAX_NAME_LENGTH = 60;

function truncateName(value, limit) {
  const characters = Array.from(value);
  if (characters.length <= limit) {
    return value;
  }
  return limit > 0 ? characters.slice(0, limit - 1).join("") + "…" : "";
}

export default class CrmOutboundSyncConfiguration extends Component {
  @service a11y;
  @service dialog;
  @service modal;

  @tracked configuration = structuredClone(
    this.args.record || createSyncConfiguration(this.args.targets?.[0])
  );
  @tracked createdGroups = [];
  @tracked hasCustomName = Boolean(
    this.configuration.name && this.configuration.name !== this.defaultTitle
  );
  @tracked saving = false;
  @tracked crmFields = [];
  @tracked customSources = [];
  @tracked fieldsTarget;
  @tracked loadingFields = false;
  @tracked fieldsError;
  formData = {
    ...this.configuration,
    target: `${this.configuration.provider || "salesforce"}:${this.configuration.object}`,
  };

  #fieldsRequest = 0;

  #form;
  #nextMappingId =
    Math.max(
      0,
      ...this.configuration.mappings.map((mapping) => Number(mapping.id))
    ) + 1;

  #initialLoad;

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this.#initialLoad);
  }

  get title() {
    return this.hasCustomName ? this.configuration.name : this.defaultTitle;
  }

  get defaultTitle() {
    const groups = this.selectedGroups;
    const scope =
      groups.length === 1 ? "group" : groups.length ? "groups" : "users";
    const key = `${PREFIX}.default_names.${this.targetDefinition.translationKey}.${scope}`;
    const templateLength = Array.from(i18n(key, { group: "" })).length;
    const group = truncateName(
      groups[0]?.name || "",
      Math.max(0, MAX_NAME_LENGTH - templateLength)
    );
    return truncateName(i18n(key, { group }), MAX_NAME_LENGTH);
  }

  get groups() {
    return [...(this.args.groups || []), ...this.createdGroups].reduce(
      (groups, group) => {
        if (!groups.some((item) => String(item.id) === String(group.id))) {
          groups.push({
            ...group,
            label: Number.isInteger(group.user_count)
              ? i18n(`${PREFIX}.group_option`, {
                  name: group.name,
                  count: group.user_count,
                })
              : group.name,
          });
        }
        return groups;
      },
      []
    );
  }

  get selectedGroups() {
    return this.configuration.group_ids.map(
      (id, index) =>
        this.groups.find((group) => String(group.id) === String(id)) || {
          id,
          name: this.configuration.groups[index],
        }
    );
  }

  get backfillLabel() {
    const count =
      this.configuration.group_ids.length === 1
        ? this.groups.find(
            (group) =>
              String(group.id) === String(this.configuration.group_ids[0])
          )?.user_count
        : null;
    return Number.isInteger(count)
      ? i18n(`${PREFIX}.backfill`, { count })
      : i18n(`${PREFIX}.backfill_without_count`);
  }

  get targetDefinition() {
    return outboundTarget(
      this.configuration.provider || "salesforce",
      this.configuration.object
    );
  }

  get emailField() {
    return this.targetDefinition.emailField;
  }

  get providerName() {
    return this.targetDefinition.name;
  }

  get target() {
    return `${this.configuration.provider || "salesforce"}:${this.configuration.object}`;
  }

  get targets() {
    return (this.args.targets || []).map((target) => ({
      ...target,
      id: `${target.provider}:${target.object}`,
      label: targetLabel(target.provider, target.object),
    }));
  }

  get selectedTargetLabel() {
    return targetLabel(
      this.configuration.provider || "salesforce",
      this.configuration.object
    );
  }

  get fields() {
    return this.crmFields.filter((field) => field.id !== this.emailField);
  }

  get sources() {
    return [
      ...USER_SYNC_SOURCES.map((source) => ({
        ...source,
        label: i18n(`${PREFIX}.sources.${source.id}`),
      })),
      ...this.customSources.map((source) => ({
        ...source,
        group: "custom",
        label: source.name,
      })),
    ];
  }

  get scheduleTiming() {
    return i18n(`${PREFIX}.schedule_timing.${this.configuration.schedule}`);
  }

  get submitLabel() {
    return `${PREFIX}.${
      !this.args.record?.id && this.configuration.backfill
        ? "save_and_send"
        : "save_changes"
    }`;
  }

  @action
  async createGroup(menu) {
    await menu.close();
    this.modal.show(CrmCreateGroupModal, {
      model: { onCreated: this.groupCreated },
    });
  }

  @action
  groupCreated(group) {
    this.createdGroups = [...this.createdGroups, group];
    if (!this.configuration.group_ids.map(String).includes(String(group.id))) {
      this.selectGroups([...this.selectedGroups, group]);
    }
    this.a11y.announce(i18n(`${PREFIX}.group_created`, { name: group.name }));
  }

  @action
  async findGroups(query) {
    try {
      const result = await ajax("/salesforce/admin/guided-sync/groups.json", {
        data: { q: query || "" },
      });
      return [
        ...new Map(
          [...result.groups, ...this.createdGroups].map((group) => [
            String(group.id),
            group,
          ])
        ).values(),
      ];
    } catch {
      return this.groups.filter((group) =>
        group.name.toLowerCase().includes((query || "").toLowerCase())
      );
    }
  }

  @action
  compareGroups(a, b) {
    return String(a.id) === String(b.id);
  }

  @action
  selectGroups(groups) {
    const groupIds = groups.map((group) => group.id);
    const names = groups.map((group) => group.name);
    this.#form.set("group_ids", groupIds);
    this.configuration = {
      ...this.configuration,
      group_ids: groupIds,
      groups: names,
    };
  }

  @action
  addMapping() {
    this.#setMappings([
      ...this.configuration.mappings,
      {
        id: this.#nextMappingId++,
        source: "",
        destination: "",
        policy: "overwrite",
      },
    ]);
  }

  @action
  validateConfiguration(data, { addError, removeError }) {
    removeError("mappings");
    if (
      this.fieldsError ||
      this.loadingFields ||
      this.fieldsTarget !== this.target
    ) {
      addError("target", {
        title: i18n(`${PREFIX}.target`),
        message: this.fieldsError || i18n(`${PREFIX}.errors.loading_fields`),
      });
      return;
    }
    const required = this.targetDefinition.requiredFields;
    for (const field of required) {
      if (!data.mappings.some((mapping) => mapping.destination === field)) {
        addError("mappings", {
          title: i18n(`${PREFIX}.mapping_title`),
          message: i18n(`${PREFIX}.errors.required_field`, { field }),
        });
      }
    }
  }

  @action
  validateSource(name, value, { addError }) {
    if (value && !this.sources.some((source) => source.id === value)) {
      addError(name, {
        title: i18n(`${PREFIX}.discourse_field`),
        message: i18n(`${PREFIX}.errors.source_unavailable`),
      });
    }
  }

  @action
  validateDestination(name, value, { data, addError }) {
    if (!value || this.loadingFields || this.fieldsError) {
      return;
    }
    const field = this.crmFields.find((candidate) => candidate.id === value);
    let message;
    if (!field) {
      message = i18n(`${PREFIX}.errors.unavailable`, { fields: value });
    } else {
      const mapping = data.mappings[Number(name.split(".")[1])];
      const source = this.sources.find(
        (candidate) => candidate.id === mapping.source
      );
      if (source && source.type !== field.type) {
        message = i18n(`${PREFIX}.errors.incompatible`, {
          source: source.label,
          source_type: source.type,
          destination: field.id,
          destination_type: field.type,
        });
      }
    }
    if (message) {
      addError(name, { title: i18n(`${PREFIX}.salesforce_field`), message });
    }
  }

  @action
  validateStaticValue(name, value, { addError }) {
    if (value === null || value === undefined || value === "") {
      return;
    }
    if (typeof value !== "string" || !value.trim() || value.length > 1000) {
      addError(name, {
        title: i18n(`${PREFIX}.static_value`),
        message: i18n(`${PREFIX}.errors.static_value`),
      });
    }
  }

  @action
  async save() {
    if (this.saving || !this.args.onSave) {
      return;
    }
    this.saving = true;
    try {
      if (await this.args.onSave({ ...this.configuration, name: this.title })) {
        this.a11y.announce(i18n(`${PREFIX}.save_success`));
      }
    } finally {
      this.saving = false;
    }
  }

  @action
  cancelSetup() {
    this.dialog.confirm({
      title: i18n(`${PREFIX}.cancel_title`),
      message: i18n(`${PREFIX}.cancel_message`),
      confirmButtonLabel: `${PREFIX}.discard_changes`,
      confirmButtonClass: "btn-danger",
      cancelButtonLabel: `${PREFIX}.keep_editing`,
      didConfirm: () => this.args.onCancel(),
    });
  }

  @action
  allowNavigation() {
    return false;
  }

  @action
  async refreshFields(force = false) {
    const object = this.configuration.object;
    const provider = this.configuration.provider || "salesforce";
    const target = this.target;
    const request = ++this.#fieldsRequest;
    this.loadingFields = true;
    this.fieldsError = null;
    this.crmFields = [];
    this.fieldsTarget = null;
    try {
      const url = this.targetDefinition.metadataUrl;
      const result = await ajax(url, {
        data: { provider, object, refresh: force },
      });
      if (
        this.isDestroying ||
        this.isDestroyed ||
        request !== this.#fieldsRequest ||
        target !== this.target
      ) {
        return;
      }
      this.customSources = result.custom_sources || [];
      this.crmFields = result.fields.map((field) => ({
        id: field.name,
        label: field.label || field.name,
        custom: field.custom,
        type: ["int", "double", "currency", "percent"].includes(field.type)
          ? "number"
          : ["date", "datetime"].includes(field.type)
            ? "date"
            : [
                  "string",
                  "textarea",
                  "email",
                  "phone",
                  "url",
                  "picklist",
                  "multipicklist",
                  "combobox",
                  "encryptedstring",
                ].includes(field.type)
              ? "text"
              : field.type,
      }));
      this.fieldsTarget = target;
      this.#form.removeError("target");
      if (this.crmFields.length === 0) {
        this.fieldsError = i18n(`${PREFIX}.fields_not_writable`);
      }
    } catch (error) {
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#fieldsRequest &&
        target === this.target
      ) {
        this.fieldsError = extractError(error, i18n(`${PREFIX}.fields_failed`));
      }
    } finally {
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#fieldsRequest
      ) {
        this.loadingFields = false;
      }
    }
  }

  @action
  applyName(value) {
    this.#form?.set("name", value);
    this.hasCustomName = value !== this.defaultTitle;
    this.configuration = { ...this.configuration, name: value };
  }

  @action
  registerForm(form) {
    this.#form = form;
    this.#initialLoad = next(this, () => {
      this.refreshFields();
    });
  }

  @action
  removeMapping(index) {
    this.#setMappings(
      this.configuration.mappings.filter(
        (mapping, mappingIndex) => mappingIndex !== index
      )
    );
  }

  @action
  setConfiguration(value, { name, set }) {
    set(name, value);
    this.configuration = { ...this.configuration, [name]: value };
    if (name === "target") {
      const target = this.targets.find((item) => item.id === value);
      if (!target) {
        return;
      }
      const providerChanged =
        target.provider !== (this.configuration.provider || "salesforce");
      this.#form.set("provider", target.provider);
      this.#form.set("object", target.object);
      this.configuration = {
        ...this.configuration,
        provider: target.provider,
        object: target.object,
      };
      const mappings = providerChanged
        ? this.targetDefinition.createMappings()
        : this.targetDefinition.adaptMappings?.(
            this.configuration.mappings,
            this.#nextMappingId
          ) || this.configuration.mappings;
      this.#setMappings(mappings);
      this.#nextMappingId =
        Math.max(0, ...mappings.map((mapping) => Number(mapping.id))) + 1;
      this.refreshFields();
    }
  }

  @action
  setMapping(property, value, { index }) {
    this.#setMappings(
      updateMapping(this.configuration, index, property, value)
    );
  }

  #setMappings(mappings) {
    this.#form?.set("mappings", mappings);
    this.configuration = { ...this.configuration, mappings };
  }

  <template>
    <div
      class="salesforce-sync-configuration admin-config-page__main-area"
      ...attributes
    >
      <SyncConfigurationHeading
        class="salesforce-sync-configuration__heading"
        @editable={{@onSave}}
        @onApply={{this.applyName}}
        @title={{this.title}}
      />
      <p>{{i18n "salesforce.guided_sync.description"}}</p>

      <Form
        class="salesforce-sync-configuration__form"
        @data={{this.formData}}
        @onDirtyCheck={{this.allowNavigation}}
        @onRegisterApi={{this.registerForm}}
        @onSubmit={{this.save}}
        @validate={{this.validateConfiguration}}
        @validateOn="submit"
        as |form|
      >
        <section
          class="salesforce-sync-configuration__section"
          aria-labelledby="salesforce-scope-title"
        >
          <h3 id="salesforce-scope-title">{{i18n
              "salesforce.guided_sync.scope_title"
            }}</h3>
          <p class="salesforce-sync-configuration__description">{{i18n
              "salesforce.guided_sync.scope_description"
            }}</p>

          <div class="salesforce-sync-configuration__scope-fields">
            <form.Field
              @format="full"
              @name="group_ids"
              @title={{i18n "salesforce.guided_sync.group"}}
              @type="custom"
              @validation="required"
              as |field|
            >
              <field.Control>
                <div class="salesforce-sync-configuration__group-controls">
                  <DMultiSelect
                    @compareFn={{this.compareGroups}}
                    @label={{i18n "salesforce.guided_sync.group"}}
                    @loadFn={{this.findGroups}}
                    @matchTriggerWidth={{true}}
                    @onChange={{this.selectGroups}}
                    @selection={{this.selectedGroups}}
                  >
                    <:selection as |group|>{{group.name}}</:selection>
                    <:result as |group|>{{group.name}}</:result>
                    <:footer as |menu|>
                      <DButton
                        class="btn-flat salesforce-sync-configuration__create-group"
                        data-test-create-group
                        @action={{fn this.createGroup menu}}
                        @icon="plus"
                        @label="salesforce.guided_sync.create_group"
                      />
                    </:footer>
                  </DMultiSelect>
                </div>
              </field.Control>
            </form.Field>
            <form.Field
              @disabled={{@record.id}}
              @name="target"
              @onSet={{this.setConfiguration}}
              @title={{i18n "salesforce.guided_sync.target"}}
              @type="menu"
              @validation="required"
              as |field|
            >
              <field.Control @selection={{this.selectedTargetLabel}} as |menu|>
                {{#each this.targets key="id" as |target|}}
                  <menu.Item @value={{target.id}}>{{target.label}}</menu.Item>
                {{/each}}
              </field.Control>
            </form.Field>

          </div>
        </section>
        <section
          class="salesforce-sync-configuration__section"
          aria-labelledby="salesforce-behavior-title"
        >
          <h3 id="salesforce-behavior-title">{{i18n
              "salesforce.guided_sync.behavior_title"
            }}</h3>
          <p class="salesforce-sync-configuration__description">{{i18n
              "salesforce.guided_sync.behavior_description"
            }}</p>

          <div class="salesforce-sync-configuration__behavior-fields">
            <form.Field
              @format="full"
              @name="backfill"
              @onSet={{this.setConfiguration}}
              @title={{this.backfillLabel}}
              @type="checkbox"
              as |field|
            >
              <field.Control />
            </form.Field>
            <form.Field
              class="salesforce-sync-configuration__schedule"
              @format="full"
              @helpText={{this.scheduleTiming}}
              @name="schedule"
              @onSet={{this.setConfiguration}}
              @title={{i18n "salesforce.guided_sync.schedule"}}
              @tooltip={{i18n "salesforce.guided_sync.schedule_help"}}
              @type="menu"
              @validation="required"
              as |field|
            >
              <field.Control
                @selection={{this.configuration.schedule}}
                as |menu|
              >
                <menu.Item @value="hourly">{{i18n
                    "salesforce.guided_sync.schedules.hourly"
                  }}</menu.Item>
                <menu.Item @value="daily">{{i18n
                    "salesforce.guided_sync.schedules.daily"
                  }}</menu.Item>
                <menu.Item @value="weekly">{{i18n
                    "salesforce.guided_sync.schedules.weekly"
                  }}</menu.Item>
                <menu.Item @value="manual">{{i18n
                    "salesforce.guided_sync.schedules.manual"
                  }}</menu.Item>
              </field.Control>
            </form.Field>
          </div>

        </section>
        <section
          class="salesforce-sync-configuration__section"
          aria-labelledby="salesforce-mapping-title"
        >
          <h3 id="salesforce-mapping-title">{{i18n
              "salesforce.guided_sync.mapping_title"
            }}</h3>
          <p class="salesforce-sync-configuration__description">{{i18n
              "salesforce.guided_sync.mapping_description"
            }}</p>
          <DConditionalLoadingSpinner
            data-test-fields-loading
            aria-busy={{this.loadingFields}}
            @condition={{this.loadingFields}}
          >
            {{#if this.fieldsError}}
              <form.Alert @type="error">{{this.fieldsError}}</form.Alert>
              <DButton
                class="btn-default salesforce-sync-configuration__retry-fields"
                data-test-refresh-fields
                @action={{fn this.refreshFields true}}
                @icon="arrows-rotate"
                @label="salesforce.guided_sync.retry_fields"
              />
            {{else}}
              <div class="salesforce-sync-configuration__mapping-headings">
                <span>{{i18n "salesforce.guided_sync.discourse_field"}}</span>
                <span
                  class="salesforce-sync-configuration__arrow-heading"
                ></span>
                <span>{{i18n "salesforce.guided_sync.salesforce_field"}}</span>
                <span>{{i18n "salesforce.guided_sync.existing_value"}}
                  <DTooltip
                    aria-label={{i18n "salesforce.guided_sync.existing_value"}}
                    @icon="far-circle-question"
                    @identifier="salesforce-field-policy"
                  >
                    <:content>{{i18n
                        "salesforce.guided_sync.policy_help"
                      }}</:content>
                  </DTooltip>
                </span>
              </div>
              <div class="salesforce-sync-configuration__locked-mapping">
                <span>{{dIcon "lock"}}
                  {{i18n "salesforce.guided_sync.email"}}</span>
                <span
                  class="salesforce-sync-configuration__mapping-arrow"
                >{{dIcon "arrow-right"}}</span>
                <code>{{this.emailField}}</code>
                <span>{{i18n "salesforce.guided_sync.fixed_mapping"}}</span>
                <p class="salesforce-sync-configuration__email-help">{{i18n
                    "salesforce.guided_sync.matching_help"
                  }}</p>
              </div>
              <div
                class="salesforce-sync-configuration__mapping-list"
                id="control-mappings"
              >
                <form.Collection @name="mappings" as |collection index mapping|>
                  <div
                    class="salesforce-sync-configuration__mapping-row"
                    data-test-mapping={{mapping.id}}
                  >
                    <div class="salesforce-sync-configuration__mapping-source">
                      <collection.Field
                        @format="full"
                        @name="source"
                        @onSet={{fn this.setMapping "source"}}
                        @validate={{this.validateSource}}
                        @title={{i18n "salesforce.guided_sync.discourse_field"}}
                        @type="menu"
                        @validation="required"
                        as |field|
                      >
                        <CrmSourceMenu
                          @control={{field.Control}}
                          @sources={{this.sources}}
                          @value={{mapping.source}}
                        />
                      </collection.Field>
                      {{#if (eq mapping.source "static")}}
                        <collection.Field
                          @format="full"
                          @name="value"
                          @showTitle={{false}}
                          @onSet={{fn this.setMapping "value"}}
                          @validate={{this.validateStaticValue}}
                          @title={{i18n "salesforce.guided_sync.static_value"}}
                          @type="input"
                          @validation="required"
                          as |field|
                        >
                          <field.Control
                            aria-label={{i18n
                              "salesforce.guided_sync.static_value"
                            }}
                            maxlength="1000"
                            placeholder={{i18n
                              "salesforce.guided_sync.static_value"
                            }}
                          />
                        </collection.Field>
                      {{/if}}
                    </div>
                    <span
                      class="salesforce-sync-configuration__mapping-arrow"
                    >{{dIcon "arrow-right"}}</span>
                    <collection.Field
                      @description={{if
                        mapping.moved
                        (i18n "salesforce.guided_sync.field_moved")
                      }}
                      @format="full"
                      @name="destination"
                      @onSet={{fn this.setMapping "destination"}}
                      @validate={{this.validateDestination}}
                      @title={{i18n "salesforce.guided_sync.salesforce_field"}}
                      @type="menu"
                      @validation="required"
                      as |field|
                    >
                      <CrmFieldMenu
                        @control={{field.Control}}
                        @value={{mapping.destination}}
                        @fields={{this.fields}}
                        @mappings={{this.configuration.mappings}}
                        @mappingId={{mapping.id}}
                        @sources={{this.sources}}
                      />
                    </collection.Field>
                    <collection.Field
                      @format="full"
                      @name="policy"
                      @onSet={{fn this.setMapping "policy"}}
                      @title={{i18n "salesforce.guided_sync.existing_value"}}
                      @type="menu"
                      @validation="required"
                      as |field|
                    >
                      <field.Control
                        aria-label={{i18n
                          "salesforce.guided_sync.existing_value"
                        }}
                        @selection={{if
                          (eq mapping.policy "keep")
                          this.providerName
                          (i18n "salesforce.guided_sync.overwrite")
                        }}
                        as |menu|
                      >
                        <menu.Item
                          @value="keep"
                        >{{this.providerName}}</menu.Item>
                        <menu.Item @value="overwrite">{{i18n
                            "salesforce.guided_sync.overwrite"
                          }}</menu.Item>
                      </field.Control>
                    </collection.Field>
                    <DButton
                      class="btn-transparent salesforce-sync-configuration__remove"
                      data-test-remove-mapping={{mapping.id}}
                      @action={{fn this.removeMapping index}}
                      @icon="trash-can"
                      @title="salesforce.guided_sync.remove_mapping"
                    />
                  </div>
                </form.Collection>
              </div>
              <div class="salesforce-sync-configuration__actions --spread">
                <DButton
                  class="btn-flat"
                  data-test-add-mapping
                  @action={{this.addMapping}}
                  @icon="plus"
                  @label="salesforce.guided_sync.add_mapping"
                />
                <DButton
                  class="btn-flat"
                  data-test-refresh-fields
                  @action={{fn this.refreshFields true}}
                  @disabled={{this.loadingFields}}
                  @icon="arrows-rotate"
                  @label="salesforce.guided_sync.refresh_fields"
                />
              </div>
            {{/if}}
          </DConditionalLoadingSpinner>

        </section>
        <form.Actions class="salesforce-sync-configuration__footer">
          {{#if @onCancel}}
            <DButton
              class="btn-flat"
              data-test-configurations-back
              @action={{this.cancelSetup}}
              @disabled={{this.saving}}
              @label="salesforce.guided_sync.cancel_setup"
            />
          {{/if}}
          <form.Submit
            data-test-save
            @disabled={{this.saving}}
            @label={{this.submitLabel}}
          />
        </form.Actions>
      </Form>

    </div>
  </template>
}
