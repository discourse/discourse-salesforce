import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AdminConfigAreaCard from "discourse/admin/components/admin-config-area-card";
import Form from "discourse/components/form";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { eq, not, or } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DFilterInput from "discourse/ui-kit/d-filter-input";
import DMultiSelect from "discourse/ui-kit/d-multi-select";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import SalesforceCreateGroupModal from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-create-group-modal";
import SalesforceFieldMenu from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-field-menu";
import SalesforceSourceMenu from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-source-menu";
import {
  createDemoConfiguration,
  DEMO_SOURCES,
  mappingError,
  normalizeConfiguration,
  updateMapping,
} from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-demo";

const PREFIX = "salesforce.guided_sync";

export default class SalesforceGuidedSync extends Component {
  @service a11y;
  @service dialog;
  @service modal;

  @tracked configuration = normalizeConfiguration(
    this.args.record || createDemoConfiguration()
  );
  @tracked createdGroups = [];
  @tracked nameFormData;
  @tracked enabled = false;
  @tracked message;
  @tracked step = 1;
  @tracked saving = false;
  @tracked salesforceFields = [];
  @tracked customSources = [];
  @tracked fieldsObject;
  @tracked loadingFields = false;
  @tracked fieldsError;
  @tracked previewRows = [];
  @tracked samplePreview = false;
  @tracked previewUser;
  @tracked previewUsers = [];
  @tracked previewQuery = "";
  @tracked previewError;
  @tracked loadingPreview = false;
  @tracked loadingPreviewUsers = false;
  @tracked previewUsersError;
  formData = this.configuration;

  #previewRequest = 0;
  #previewUsersRequest = 0;

  #fieldsRequest = 0;

  #form;
  #nextMappingId =
    Math.max(
      0,
      ...this.configuration.mappings.map((mapping) => Number(mapping.id))
    ) + 1;

  get title() {
    return this.configuration.name || i18n(`${PREFIX}.default_users_name`);
  }

  get groups() {
    return [...(this.args.groups || []), ...this.createdGroups].map(
      (group) => ({
        ...group,
        label: Number.isInteger(group.user_count)
          ? i18n(`${PREFIX}.group_option`, {
              name: group.name,
              count: group.user_count,
            })
          : group.name,
      })
    );
  }

  get selectedGroups() {
    return this.configuration.groups.map((name) => ({ name }));
  }

  get backfillLabel() {
    const count =
      this.configuration.groups.length === 1
        ? this.groups.find(
            (group) => group.name === this.configuration.groups[0]
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
      ...DEMO_SOURCES.map((source) => ({
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

  get steps() {
    return ["scope", "mapping", "behavior", "review"].map((id, index) => ({
      id,
      index: index + 1,
      number: index + 1,
      label: i18n(`${PREFIX}.steps.${id}`),
      current: this.step === index + 1,
      completed: this.step > index + 1,
    }));
  }

  get error() {
    const error = mappingError(
      this.configuration,
      this.salesforceFields,
      this.sources
    );
    if (error === "incompatible") {
      const mapping = this.configuration.mappings.find((item) => {
        const source = this.sources.find(
          (candidate) => candidate.id === item.source
        );
        const field = this.salesforceFields.find(
          (candidate) => candidate.id === item.destination
        );
        return field && source?.type !== field.type;
      });
      const source = this.sources.find((item) => item.id === mapping.source);
      const field = this.salesforceFields.find(
        (item) => item.id === mapping.destination
      );
      return i18n(`${PREFIX}.errors.incompatible`, {
        source: source?.label || mapping.source,
        source_type: source?.type || i18n(`${PREFIX}.unknown_type`),
        destination: field.id,
        destination_type: field.type,
      });
    }
    return error
      ? i18n(`${PREFIX}.errors.${error}`, {
          fields: this.configuration.mappings
            .filter(
              (mapping) =>
                mapping.destination &&
                !this.salesforceFields.some(
                  (field) => field.id === mapping.destination
                )
            )
            .map((mapping) => mapping.destination)
            .join(", "),
        })
      : null;
  }

  get continueDisabled() {
    return (
      this.saving ||
      !this.configuration.groups.length ||
      (this.step >= 2 &&
        (this.loadingFields ||
          this.fieldsObject !== this.configuration.object ||
          Boolean(this.fieldsError) ||
          Boolean(this.error)))
    );
  }

  get canGoBack() {
    return this.step > 1;
  }

  get scheduleTiming() {
    return i18n(`${PREFIX}.schedule_timing.${this.configuration.schedule}`);
  }

  get submitLabel() {
    return this.step === 4
      ? `${PREFIX}.${this.enabled ? "save_changes" : "enable"}`
      : `${PREFIX}.continue`;
  }

  get preview() {
    return this.previewRows.map((row) => ({
      ...row,
      current: row.current ?? "—",
      incoming: row.incoming === "" ? "—" : (row.incoming ?? "—"),
      result: row.result === "" ? "—" : (row.result ?? "—"),
      outcomeLabel: i18n(`${PREFIX}.outcomes.${row.outcome}`),
      kept: row.outcome === "kept",
    }));
  }

  @action
  createGroup() {
    this.modal.show(SalesforceCreateGroupModal, {
      model: { onCreated: this.groupCreated },
    });
  }

  @action
  groupCreated(group) {
    this.createdGroups = [...this.createdGroups, group];
    if (!this.configuration.groups.includes(group.name)) {
      this.selectGroups([...this.selectedGroups, group]);
    }
    this.a11y.announce(i18n(`${PREFIX}.group_created`, { name: group.name }));
  }

  @action
  async findGroups(query) {
    const result = await ajax(
      "/salesforce/admin/guided-sync/configurations.json"
    );
    return result.groups.filter((group) =>
      group.name.toLowerCase().includes((query || "").toLowerCase())
    );
  }

  @action
  compareGroups(a, b) {
    return a.name === b.name;
  }

  @action
  selectGroups(groups) {
    const names = groups.map((group) => group.name);
    this.#form.set("groups", names);
    this.configuration = { ...this.configuration, groups: names };
    this.previewUser = null;
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
  async advance() {
    if (this.continueDisabled) {
      return;
    }
    if (this.step < 4) {
      this.message = null;
      this.goToStep(this.step + 1);
      return;
    }
    if (this.args.onSave) {
      this.saving = true;
      try {
        if (!(await this.args.onSave(this.configuration))) {
          return;
        }
      } finally {
        this.saving = false;
      }
    }
    const wasEnabled = this.enabled;
    this.enabled = true;
    if (this.args.onSave) {
      this.message = null;
      this.a11y.announce(i18n(`${PREFIX}.save_success`));
    } else {
      this.#notify(wasEnabled ? "saved_message" : "enabled_message");
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
  goToStep(index) {
    this.message = null;
    this.step = index;
    this.#previewRequest++;
    this.#previewUsersRequest++;
    if (index === 4) {
      this.previewQuery = "";
      this.searchPreviewUsers();
      this.loadPreview();
    }
    if (index >= 2 && this.fieldsObject !== this.configuration.object) {
      this.refreshFields();
    }
  }

  @action
  previousStep() {
    this.goToStep(this.step - 1);
  }

  @action
  async refreshFields() {
    const object = this.configuration.object;
    const request = ++this.#fieldsRequest;
    this.loadingFields = true;
    this.fieldsError = null;
    this.salesforceFields = [];
    this.fieldsObject = null;
    try {
      const result = await ajax("/salesforce/admin/guided-sync/fields.json", {
        data: { object },
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
      if (this.salesforceFields.length === 0) {
        this.fieldsError = i18n(`${PREFIX}.fields_not_writable`);
      }
    } catch {
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#fieldsRequest &&
        object === this.configuration.object
      ) {
        this.fieldsError = i18n(`${PREFIX}.fields_failed`);
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
  async loadPreview() {
    const request = ++this.#previewRequest;
    this.loadingPreview = true;
    this.previewError = null;
    this.previewRows = [];
    this.samplePreview = false;
    try {
      const result = await ajax("/salesforce/admin/guided-sync/preview.json", {
        type: "POST",
        contentType: "application/json",
        data: JSON.stringify({
          configuration: this.configuration,
          user_id: this.previewUser?.id,
        }),
      });
      if (
        this.isDestroying ||
        this.isDestroyed ||
        request !== this.#previewRequest
      ) {
        return;
      }
      this.previewUser = result.user;
      this.samplePreview = result.sample === true;
      this.previewRows = result.rows;
    } catch (error) {
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#previewRequest
      ) {
        this.previewError = extractError(error);
      }
    } finally {
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#previewRequest
      ) {
        this.loadingPreview = false;
      }
    }
  }

  @action
  async searchPreviewUsers() {
    const request = ++this.#previewUsersRequest;
    this.loadingPreviewUsers = true;
    this.previewUsersError = null;
    this.previewUsers = [];
    try {
      const result = await ajax(
        "/salesforce/admin/guided-sync/preview-users.json",
        {
          data: { groups: this.configuration.groups, q: this.previewQuery },
        }
      );
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#previewUsersRequest
      ) {
        this.previewUsers = result.users;
      }
    } catch (error) {
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#previewUsersRequest
      ) {
        this.previewUsersError = extractError(error);
      }
    } finally {
      if (
        !this.isDestroying &&
        !this.isDestroyed &&
        request === this.#previewUsersRequest
      ) {
        this.loadingPreviewUsers = false;
      }
    }
  }

  @action
  filterPreviewUsers(event) {
    this.previewQuery = event.target.value;
    this.searchPreviewUsers();
  }

  @action
  selectPreviewUser(user) {
    this.previewUser = user;
    this.loadPreview();
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
        {
          id: this.#nextMappingId++,
          source: "company",
          destination: "Company",
          policy: "overwrite",
        },
      ]);
    }
    if (name === "object" && value === "Contact" && !this.args.record?.id) {
      this.#setMappings(
        this.configuration.mappings.filter(
          (mapping) => mapping.destination !== "Company"
        )
      );
    }
  }

  @action
  setMapping(property, value, { index }) {
    this.#setMappings(
      updateMapping(this.configuration, index, property, value)
    );
  }

  #notify(key) {
    this.message = i18n(`${PREFIX}.${key}`);
    this.a11y.announce(this.message);
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
      </div>
      {{#if this.nameFormData}}
        <Form
          class="salesforce-guided-sync__name-form"
          @data={{this.nameFormData}}
          @onSubmit={{this.applyName}}
          as |nameForm|
        >
          <nameForm.Field
            @name="name"
            @title={{i18n "salesforce.guided_sync.configuration_name"}}
            @type="input"
            @validation="required"
            as |field|
          >
            <field.Control @autofocus={{true}} @maxlength={{60}} />
          </nameForm.Field>
          <div class="salesforce-guided-sync__name-actions">
            <nameForm.Submit @label="salesforce.guided_sync.apply_name" />
            <DButton
              class="btn-transparent"
              @action={{this.cancelNameEdit}}
              @label="cancel"
            />
          </div>
        </Form>
      {{/if}}
      <p>{{i18n "salesforce.guided_sync.description"}}</p>

      <nav
        class="salesforce-guided-sync__steps"
        aria-label={{i18n "salesforce.guided_sync.steps_label"}}
      >
        {{#each this.steps as |step|}}
          <DButton
            class={{dConcatClass
              "btn-transparent salesforce-guided-sync__step"
              (if step.current "--current")
              (if step.completed "--completed")
            }}
            aria-current={{if step.current "step"}}
            data-test-step={{step.id}}
            @action={{fn this.goToStep step.index}}
            @disabled={{not step.completed}}
          >
            <span class="salesforce-guided-sync__step-number">
              {{#if step.completed}}
                {{dIcon "check"}}
              {{else}}
                {{step.number}}
              {{/if}}
            </span>
            {{step.label}}
          </DButton>
        {{/each}}
      </nav>

      <Form
        class="salesforce-guided-sync__form"
        @data={{this.formData}}
        @onDirtyCheck={{this.allowNavigation}}
        @onRegisterApi={{this.registerForm}}
        @onSubmit={{this.advance}}
        as |form|
      >
        {{#if (eq this.step 1)}}
          <AdminConfigAreaCard
            class="salesforce-guided-sync__form-card"
            @description="salesforce.guided_sync.scope_description"
            @heading="salesforce.guided_sync.scope_title"
          >
            <:content>
              <form.Field
                @format="full"
                @name="groups"
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
                      @onChange={{this.selectGroups}}
                      @selection={{this.selectedGroups}}
                    >
                      <:selection as |group|>{{group.name}}</:selection>
                      <:result as |group|>{{group.name}}</:result>
                    </DMultiSelect>
                    <DButton
                      class="btn-transparent"
                      data-test-create-group
                      @action={{this.createGroup}}
                      @icon="plus"
                      @label="salesforce.guided_sync.create_group"
                    />
                  </div>
                </field.Control>
              </form.Field>
              <form.Field
                @disabled={{@record.id}}
                @name="object"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.target"}}
                @type="select"
                @validation="required"
                as |field|
              >
                <field.Control @includeNone={{false}} as |select|>
                  <select.Option @value="Lead">{{i18n
                      "salesforce.guided_sync.leads"
                    }}</select.Option>
                  <select.Option @value="Contact">{{i18n
                      "salesforce.guided_sync.contacts"
                    }}</select.Option>
                </field.Control>
              </form.Field>
            </:content>
          </AdminConfigAreaCard>
        {{else if (eq this.step 2)}}
          <AdminConfigAreaCard
            @description="salesforce.guided_sync.matching_help"
            @heading="salesforce.guided_sync.mapping_title"
          >
            <:content>
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
                    @action={{this.refreshFields}}
                    @icon="arrows-rotate"
                    @label="salesforce.guided_sync.retry_fields"
                  />
                {{else}}
                  <div class="salesforce-guided-sync__mapping-headings">
                    <span>{{i18n
                        "salesforce.guided_sync.discourse_field"
                      }}</span>
                    <span class="salesforce-guided-sync__arrow-heading"></span>
                    <span>{{i18n
                        "salesforce.guided_sync.salesforce_field"
                      }}</span>
                    <span>{{i18n "salesforce.guided_sync.existing_value"}}
                      <DTooltip
                        aria-label={{i18n
                          "salesforce.guided_sync.existing_value"
                        }}
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
                  </div>
                  <div class="salesforce-guided-sync__mapping-list">
                    <form.Collection
                      @name="mappings"
                      as |collection index mapping|
                    >
                      <div
                        class="salesforce-guided-sync__mapping-row"
                        data-test-mapping={{mapping.id}}
                      >
                        <div class="salesforce-guided-sync__mapping-source">
                          <collection.Field
                            @format="full"
                            @helpText={{if
                              (eq mapping.source "company")
                              (i18n "salesforce.guided_sync.company_help")
                            }}
                            @name="source"
                            @showTitle={{false}}
                            @onSet={{fn this.setMapping "source"}}
                            @title={{i18n
                              "salesforce.guided_sync.discourse_field"
                            }}
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
                              @title={{i18n
                                "salesforce.guided_sync.static_value"
                              }}
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
                          class="salesforce-guided-sync__mapping-arrow"
                        >{{dIcon "arrow-right"}}</span>
                        <collection.Field
                          class={{if mapping.moved "--unmapped"}}
                          @description={{if
                            mapping.moved
                            (i18n "salesforce.guided_sync.field_moved")
                          }}
                          @format="full"
                          @name="destination"
                          @onSet={{fn this.setMapping "destination"}}
                          @showTitle={{false}}
                          @title={{i18n
                            "salesforce.guided_sync.salesforce_field"
                          }}
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
                          @showTitle={{false}}
                          @onSet={{fn this.setMapping "policy"}}
                          @title={{i18n
                            "salesforce.guided_sync.existing_value"
                          }}
                          @type="select"
                          @validation="required"
                          as |field|
                        >
                          <field.Control
                            aria-label={{i18n
                              "salesforce.guided_sync.existing_value"
                            }}
                            @includeNone={{false}}
                            as |select|
                          >
                            <select.Option @value="keep">{{i18n
                                "salesforce.guided_sync.keep"
                              }}</select.Option>
                            <select.Option @value="overwrite">{{i18n
                                "salesforce.guided_sync.overwrite"
                              }}</select.Option>
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
                      @action={{this.refreshFields}}
                      @disabled={{this.loadingFields}}
                      @icon="arrows-rotate"
                      @label="salesforce.guided_sync.refresh_fields"
                    />
                  </div>
                  {{#if this.error}}
                    <form.Alert
                      @type="error"
                      @icon="triangle-exclamation"
                    >{{this.error}}</form.Alert>
                  {{/if}}
                {{/if}}
              </DConditionalLoadingSpinner>
            </:content>
          </AdminConfigAreaCard>
        {{else if (eq this.step 3)}}
          <AdminConfigAreaCard
            class="salesforce-guided-sync__form-card"
            @heading="salesforce.guided_sync.behavior_title"
            @description="salesforce.guided_sync.behavior_description"
          >
            <:content>
              <form.Field
                @name="backfill"
                @onSet={{this.setConfiguration}}
                @title={{this.backfillLabel}}
                @type="checkbox"
                as |field|
              >
                <field.Control />
              </form.Field>
              <form.Field
                @helpText={{this.scheduleTiming}}
                @name="schedule"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.schedule"}}
                @tooltip={{i18n "salesforce.guided_sync.schedule_help"}}
                @type="select"
                @validation="required"
                as |field|
              >
                <field.Control @includeNone={{false}} as |select|>
                  <select.Option @value="daily">{{i18n
                      "salesforce.guided_sync.schedules.daily"
                    }}</select.Option>
                  <select.Option @value="hourly">{{i18n
                      "salesforce.guided_sync.schedules.hourly"
                    }}</select.Option>
                  <select.Option @value="weekly">{{i18n
                      "salesforce.guided_sync.schedules.weekly"
                    }}</select.Option>
                  <select.Option @value="manual">{{i18n
                      "salesforce.guided_sync.schedules.manual"
                    }}</select.Option>
                </field.Control>
              </form.Field>
            </:content>
          </AdminConfigAreaCard>
        {{else if (eq this.step 4)}}
          <AdminConfigAreaCard
            @description="salesforce.guided_sync.review_description"
            @heading="salesforce.guided_sync.review_title"
          >
            <:content>
              <DConditionalLoadingSpinner
                data-test-preview-loading
                @condition={{this.loadingPreview}}
              >
                {{#if this.samplePreview}}
                  <p data-test-sample-preview>
                    <strong>{{i18n
                        "salesforce.guided_sync.sample_user"
                      }}</strong>
                    —
                    {{i18n "salesforce.guided_sync.sample_preview_help"}}
                  </p>
                {{else}}
                  <form.Field
                    @name="previewMember"
                    @showOptional={{false}}
                    @title={{i18n "salesforce.guided_sync.preview_user"}}
                    @type="menu"
                    as |field|
                  >
                    <field.Control
                      @selection={{this.previewUser.username}}
                      as |menu|
                    >
                      <menu.Container>
                        <DFilterInput
                          aria-label={{i18n
                            "salesforce.guided_sync.search_members"
                          }}
                          placeholder={{i18n
                            "salesforce.guided_sync.search_members"
                          }}
                          @value={{this.previewQuery}}
                          @filterAction={{this.filterPreviewUsers}}
                        />
                      </menu.Container>
                      {{#if this.loadingPreviewUsers}}
                        <menu.Container><DConditionalLoadingSpinner
                            @condition={{true}}
                          /></menu.Container>
                      {{else if this.previewUsersError}}
                        <menu.Container><p
                          >{{this.previewUsersError}}</p></menu.Container>
                      {{else}}
                        {{#each this.previewUsers as |user|}}
                          <menu.Item
                            @action={{fn this.selectPreviewUser user}}
                            @value={{user.id}}
                          >
                            {{user.username}}{{#if user.name}}
                              ·
                              {{user.name}}{{/if}}
                          </menu.Item>
                        {{else}}
                          <menu.Container><p>{{i18n
                                "salesforce.guided_sync.no_matching_members"
                              }}</p></menu.Container>
                        {{/each}}
                      {{/if}}
                    </field.Control>
                  </form.Field>
                {{/if}}
                {{#if this.previewError}}
                  <form.Alert @type="error">{{this.previewError}}</form.Alert>
                  <DButton
                    class="btn-default"
                    data-test-retry-preview
                    @action={{this.loadPreview}}
                    @label="salesforce.guided_sync.retry_fields"
                    @icon="arrows-rotate"
                  />
                {{else if (or this.previewUser this.samplePreview)}}

                  <div class="salesforce-guided-sync__preview-table">
                    <table class="d-table">
                      <thead class="d-table__header"><tr>
                          <th>{{i18n
                              "salesforce.guided_sync.salesforce_field"
                            }}</th>
                          <th>{{i18n
                              "salesforce.guided_sync.current_value"
                            }}</th>
                          <th>{{i18n
                              "salesforce.guided_sync.discourse_value"
                            }}</th>
                          <th>{{i18n "salesforce.guided_sync.after_sync"}}</th>
                        </tr></thead>
                      <tbody class="d-table__body">
                        {{#each this.preview as |row|}}
                          <tr
                            class="d-table__row"
                            data-test-preview-field={{row.field}}
                          >
                            <td class="d-table__cell --overview"><code
                              >{{row.field}}</code></td>
                            <td class="d-table__cell --detail"><div
                                class="d-table__mobile-label"
                              >{{i18n
                                  "salesforce.guided_sync.current_value"
                                }}</div>{{row.current}}</td>
                            <td class="d-table__cell --detail"><div
                                class="d-table__mobile-label"
                              >{{i18n
                                  "salesforce.guided_sync.discourse_value"
                                }}</div>{{row.incoming}}</td>
                            <td class="d-table__cell --detail"><div
                                class="d-table__mobile-label"
                              >{{i18n
                                  "salesforce.guided_sync.after_sync"
                                }}</div>
                              <strong>{{row.result}}</strong>
                              <span
                                class={{dConcatClass
                                  "salesforce-guided-sync__outcome"
                                  (if row.kept "--kept")
                                }}
                              >{{row.outcomeLabel}}</span>
                            </td>
                          </tr>
                        {{/each}}
                      </tbody>
                    </table>
                  </div>
                {{else}}
                  <p data-test-preview-empty>{{i18n
                      "salesforce.guided_sync.no_eligible_members"
                    }}</p>
                {{/if}}
              </DConditionalLoadingSpinner>
            </:content>
          </AdminConfigAreaCard>
        {{/if}}

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
          {{#if this.canGoBack}}
            <DButton
              class="btn-default"
              @action={{this.previousStep}}
              @label="salesforce.guided_sync.back"
            />
          {{/if}}
          <form.Submit
            data-test-continue
            @disabled={{this.continueDisabled}}
            @label={{this.submitLabel}}
          />
        </form.Actions>
      </Form>

      {{#if this.message}}
        <p
          class="alert alert-success salesforce-guided-sync__message"
          data-test-demo-message
        >{{this.message}}</p>
      {{/if}}

    </div>
  </template>
}
