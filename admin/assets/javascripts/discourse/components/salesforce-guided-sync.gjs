import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
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
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import SalesforceCreateGroupModal from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-create-group-modal";
import SalesforceFieldMenu from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-field-menu";
import SalesforceSourceMenu from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-source-menu";
import {
  createCompanyMapping,
  createSyncConfiguration,
  updateMapping,
  USER_SYNC_SOURCES,
} from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PREFIX = "salesforce.guided_sync";

export default class SalesforceGuidedSync extends Component {
  @service a11y;
  @service dialog;
  @service modal;

  @tracked configuration = structuredClone(
    this.args.record || createSyncConfiguration()
  );
  @tracked createdGroups = [];
  @tracked nameFormData;
  @tracked saving = false;
  @tracked salesforceFields = [];
  @tracked customSources = [];
  @tracked fieldsObject;
  @tracked loadingFields = false;
  @tracked fieldsError;
  formData = this.configuration;

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
    return this.configuration.name || i18n(`${PREFIX}.default_users_name`);
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

  get fields() {
    return this.salesforceFields.filter((field) => field.id !== "Email");
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
    this.modal.show(SalesforceCreateGroupModal, {
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
      this.fieldsObject !== data.object
    ) {
      addError("object", {
        title: i18n(`${PREFIX}.target`),
        message: this.fieldsError || i18n(`${PREFIX}.errors.loading_fields`),
      });
      return;
    }
    const required =
      data.object === "Lead" ? ["LastName", "Company"] : ["LastName"];
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
    const field = this.salesforceFields.find(
      (candidate) => candidate.id === value
    );
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
      if (await this.args.onSave(this.configuration)) {
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
    const request = ++this.#fieldsRequest;
    this.loadingFields = true;
    this.fieldsError = null;
    this.salesforceFields = [];
    this.fieldsObject = null;
    try {
      const result = await ajax("/salesforce/admin/guided-sync/fields.json", {
        data: { object, refresh: force },
      });
      if (
        this.isDestroying ||
        this.isDestroyed ||
        request !== this.#fieldsRequest ||
        object !== this.configuration.object
      ) {
        return;
      }
      this.customSources = result.custom_sources || [];
      this.salesforceFields = result.fields.map((field) => ({
        id: field.name,
        label: field.name,
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
      this.fieldsObject = object;
      this.#form.removeError("object");
      if (this.salesforceFields.length === 0) {
        this.fieldsError = i18n(`${PREFIX}.fields_not_writable`);
      }
    } catch (error) {
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#fieldsRequest &&
        object === this.configuration.object
      ) {
        this.fieldsError = (error.jqXHR || error).responseJSON?.errors?.length
          ? extractError(error)
          : i18n(`${PREFIX}.fields_failed`);
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
  editName() {
    this.nameFormData = { name: this.title };
  }

  @action
  cancelNameEdit() {
    this.nameFormData = null;
  }

  @action
  handleNameKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.cancelNameEdit();
    }
  }

  @action
  applyName({ name }) {
    const value = name.trim();
    if (!value) {
      return;
    }
    this.#form?.set("name", value);
    this.configuration = { ...this.configuration, name: value };
    this.nameFormData = null;
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
    if (
      name === "object" &&
      value === "Lead" &&
      !this.args.record?.id &&
      !this.configuration.mappings.some(
        (mapping) => mapping.destination === "Company"
      )
    ) {
      this.#setMappings([
        ...this.configuration.mappings,
        createCompanyMapping(this.#nextMappingId++),
      ]);
    }
    if (name === "object" && value === "Contact" && !this.args.record?.id) {
      this.#setMappings(
        this.configuration.mappings.filter(
          (mapping) => mapping.destination !== "Company"
        )
      );
    }
    if (name === "object") {
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
      class="salesforce-guided-sync admin-config-page__main-area"
      ...attributes
    >
      <div class="salesforce-guided-sync__heading">
        {{#if this.nameFormData}}
          <Form
            class="salesforce-guided-sync__name-form"
            @data={{this.nameFormData}}
            @onSubmit={{this.applyName}}
            @onDirtyCheck={{this.allowNavigation}}
            as |nameForm|
          >
            <nameForm.Field
              @format="full"
              @name="name"
              @showTitle={{false}}
              @title={{i18n "salesforce.guided_sync.configuration_name"}}
              @type="input"
              @validation="required"
              as |field|
            >
              <field.Control
                @autofocus={{true}}
                @maxlength={{60}}
                {{on "keydown" this.handleNameKeydown}}
              />
            </nameForm.Field>
            <div class="salesforce-guided-sync__name-actions">
              <DButton
                class="btn-primary"
                type="submit"
                @icon="check"
                @title="salesforce.guided_sync.apply_name"
              />
              <DButton
                class="btn-transparent"
                @action={{this.cancelNameEdit}}
                @icon="xmark"
                @title="cancel"
              />
            </div>
          </Form>
        {{else}}
          <DPageSubheader @titleLabel={{this.title}} />
          {{#if @onSave}}
            <DButton
              class="btn-transparent"
              data-test-edit-name
              @action={{this.editName}}
              @icon="pencil"
              @title="salesforce.guided_sync.edit_name"
            />
          {{/if}}
        {{/if}}
      </div>
      <p>{{i18n "salesforce.guided_sync.description"}}</p>

      <Form
        class="salesforce-guided-sync__form"
        @data={{this.formData}}
        @onDirtyCheck={{this.allowNavigation}}
        @onRegisterApi={{this.registerForm}}
        @onSubmit={{this.save}}
        @validate={{this.validateConfiguration}}
        @validateOn="submit"
        as |form|
      >
        <section
          class="salesforce-guided-sync__section"
          aria-labelledby="salesforce-scope-title"
        >
          <h3 id="salesforce-scope-title">{{i18n
              "salesforce.guided_sync.scope_title"
            }}</h3>
          <p class="salesforce-guided-sync__description">{{i18n
              "salesforce.guided_sync.scope_description"
            }}</p>

          <div class="salesforce-guided-sync__scope-fields">
            <form.Field
              @format="full"
              @name="group_ids"
              @title={{i18n "salesforce.guided_sync.group"}}
              @type="custom"
              @validation="required"
              as |field|
            >
              <field.Control>
                <div class="salesforce-guided-sync__group-controls">
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
                        class="btn-flat salesforce-guided-sync__create-group"
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
              @name="object"
              @onSet={{this.setConfiguration}}
              @title={{i18n "salesforce.guided_sync.target"}}
              @type="menu"
              @validation="required"
              as |field|
            >
              <field.Control @selection={{this.configuration.object}} as |menu|>
                <menu.Item @value="Lead">{{i18n
                    "salesforce.guided_sync.leads"
                  }}</menu.Item>
                <menu.Item @value="Contact">{{i18n
                    "salesforce.guided_sync.contacts"
                  }}</menu.Item>
              </field.Control>
            </form.Field>

          </div>
        </section>
        <section
          class="salesforce-guided-sync__section"
          aria-labelledby="salesforce-behavior-title"
        >
          <h3 id="salesforce-behavior-title">{{i18n
              "salesforce.guided_sync.behavior_title"
            }}</h3>
          <p class="salesforce-guided-sync__description">{{i18n
              "salesforce.guided_sync.behavior_description"
            }}</p>

          <div class="salesforce-guided-sync__behavior-fields">
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
              class="salesforce-guided-sync__schedule"
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
          class="salesforce-guided-sync__section"
          aria-labelledby="salesforce-mapping-title"
        >
          <h3 id="salesforce-mapping-title">{{i18n
              "salesforce.guided_sync.mapping_title"
            }}</h3>
          <p class="salesforce-guided-sync__description">{{i18n
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
                class="btn-default salesforce-guided-sync__retry-fields"
                data-test-refresh-fields
                @action={{fn this.refreshFields true}}
                @icon="arrows-rotate"
                @label="salesforce.guided_sync.retry_fields"
              />
            {{else}}
              <div class="salesforce-guided-sync__mapping-headings">
                <span>{{i18n "salesforce.guided_sync.discourse_field"}}</span>
                <span class="salesforce-guided-sync__arrow-heading"></span>
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
              <div class="salesforce-guided-sync__locked-mapping">
                <span>{{dIcon "lock"}}
                  {{i18n "salesforce.guided_sync.email"}}</span>
                <span class="salesforce-guided-sync__mapping-arrow">{{dIcon
                    "arrow-right"
                  }}</span>
                <code>Email</code>
                <span>{{i18n "salesforce.guided_sync.fixed_mapping"}}</span>
                <p class="salesforce-guided-sync__email-help">{{i18n
                    "salesforce.guided_sync.matching_help"
                  }}</p>
              </div>
              <div
                class="salesforce-guided-sync__mapping-list"
                id="control-mappings"
              >
                <form.Collection @name="mappings" as |collection index mapping|>
                  <div
                    class="salesforce-guided-sync__mapping-row"
                    data-test-mapping={{mapping.id}}
                  >
                    <div class="salesforce-guided-sync__mapping-source">
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
                        <SalesforceSourceMenu
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
                    <span class="salesforce-guided-sync__mapping-arrow">{{dIcon
                        "arrow-right"
                      }}</span>
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
                      <SalesforceFieldMenu
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
                        @selection={{i18n
                          (concat "salesforce.guided_sync." mapping.policy)
                        }}
                        as |menu|
                      >
                        <menu.Item @value="keep">{{i18n
                            "salesforce.guided_sync.keep"
                          }}</menu.Item>
                        <menu.Item @value="overwrite">{{i18n
                            "salesforce.guided_sync.overwrite"
                          }}</menu.Item>
                      </field.Control>
                    </collection.Field>
                    <DButton
                      class="btn-transparent salesforce-guided-sync__remove"
                      data-test-remove-mapping={{mapping.id}}
                      @action={{fn this.removeMapping index}}
                      @icon="trash-can"
                      @title="salesforce.guided_sync.remove_mapping"
                    />
                  </div>
                </form.Collection>
              </div>
              <div class="salesforce-guided-sync__actions --spread">
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
        <form.Actions class="salesforce-guided-sync__footer">
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
