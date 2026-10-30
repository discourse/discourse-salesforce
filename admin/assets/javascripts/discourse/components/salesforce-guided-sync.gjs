import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn, get } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { cancel, debounce, next } from "@ember/runloop";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DFilterInput from "discourse/ui-kit/d-filter-input";
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
  mappingError,
  normalizeConfiguration,
  updateMapping,
  USER_SYNC_SOURCES,
} from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PREFIX = "salesforce.guided_sync";

export default class SalesforceGuidedSync extends Component {
  @service a11y;
  @service dialog;
  @service modal;

  @tracked configuration = normalizeConfiguration(
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

  #previewTimer;

  #initialLoad;

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this.#previewTimer);
    cancel(this.#initialLoad);
  }

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
      ...USER_SYNC_SOURCES.filter(
        (source) =>
          source.id !== "company" ||
          this.configuration.mappings.some(
            (mapping) => mapping.source === "company"
          )
      ).map((source) => ({
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

  get saveDisabled() {
    return this.saving || this.previewDisabled;
  }

  get previewDisabled() {
    return (
      !this.configuration.groups.length ||
      this.loadingFields ||
      this.fieldsObject !== this.configuration.object ||
      Boolean(this.fieldsError) ||
      Boolean(this.error)
    );
  }

  get scheduleTiming() {
    return i18n(`${PREFIX}.schedule_timing.${this.configuration.schedule}`);
  }

  get submitLabel() {
    return `${PREFIX}.${this.args.record?.id ? "save_changes" : "enable"}`;
  }

  get preview() {
    return this.previewRows.map((row) => {
      const current = row.current === "" ? "—" : (row.current ?? "—");
      const result = row.result === "" ? "—" : (row.result ?? "—");
      const origin =
        row.field !== "Email" && row.outcome === "kept"
          ? "salesforce"
          : "discourse";

      return {
        ...row,
        current,
        incoming: row.incoming === "" ? "—" : (row.incoming ?? "—"),
        result,
        origin,
        originIcon:
          origin === "salesforce" ? "fab-salesforce" : "fab-discourse",
        originLabel: i18n(`${PREFIX}.preview_source.${origin}`),
        showPrevious: row.field !== "Email" && current !== result,
      };
    });
  }

  get previewByField() {
    return Object.fromEntries(this.preview.map((row) => [row.field, row]));
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
    this.previewQuery = "";
    this.#previewUsersRequest++;
    this.previewUsers = [];
    if (names.length) {
      this.searchPreviewUsers();
    }
    this.#schedulePreview();
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
  async save() {
    if (this.saveDisabled || !this.args.onSave) {
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
    this.#invalidatePreview();
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
        this.#schedulePreview();
      }
    }
  }

  @action
  async loadPreview() {
    if (this.previewDisabled) {
      return;
    }
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
      if (this.configuration.groups.length) {
        this.searchPreviewUsers();
      }
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

  #invalidatePreview() {
    cancel(this.#previewTimer);
    this.#previewRequest++;
    this.previewRows = [];
    this.previewError = null;
    this.samplePreview = false;
    this.loadingPreview = false;
  }

  #schedulePreview() {
    this.#invalidatePreview();
    if (!this.previewDisabled) {
      this.loadingPreview = true;
      this.#previewTimer = debounce(this, this.loadPreview, 300);
    }
  }

  #setMappings(mappings) {
    this.#form?.set("mappings", mappings);
    this.configuration = { ...this.configuration, mappings };
    this.#schedulePreview();
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
              "salesforce.guided_sync.review_description"
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
                <span class="salesforce-guided-sync__mapping-preview-heading">
                  <span>{{i18n "salesforce.guided_sync.preview_title"}}</span>
                  {{#if this.loadingPreview}}
                    <DConditionalLoadingSpinner @condition={{true}} />
                  {{else if this.previewDisabled}}
                    <span
                      class="salesforce-guided-sync__preview-unavailable"
                    >{{i18n
                        "salesforce.guided_sync.preview_unavailable"
                      }}</span>
                  {{else if this.samplePreview}}
                    <span data-test-sample-preview>{{i18n
                        "salesforce.guided_sync.sample_user"
                      }}</span>
                  {{else if this.previewUser}}
                    <form.Field
                      @name="previewMember"
                      @showOptional={{false}}
                      @showTitle={{false}}
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
                {{#let (get this.previewByField "Email") as |preview|}}
                  {{#if preview}}
                    <div
                      class="salesforce-guided-sync__mapping-preview"
                      data-test-preview-field="Email"
                    >
                      <span
                        class="salesforce-guided-sync__preview-origin"
                        role="img"
                        aria-label={{preview.originLabel}}
                      >{{dIcon preview.originIcon}}</span>
                      <div
                        class="salesforce-guided-sync__mapping-preview-value"
                      >
                        <span
                          class="salesforce-guided-sync__preview-mobile-label"
                        >{{i18n "salesforce.guided_sync.preview_title"}}</span>
                        <span>{{preview.result}}</span>
                      </div>
                    </div>
                  {{else}}
                    <span
                      class="salesforce-guided-sync__mapping-preview-empty"
                    >—</span>
                  {{/if}}
                {{/let}}
                <p class="salesforce-guided-sync__email-help">{{i18n
                    "salesforce.guided_sync.matching_help"
                  }}</p>
              </div>
              <div class="salesforce-guided-sync__mapping-list">
                <form.Collection @name="mappings" as |collection index mapping|>
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
                      class={{if mapping.moved "--unmapped"}}
                      @description={{if
                        mapping.moved
                        (i18n "salesforce.guided_sync.field_moved")
                      }}
                      @format="full"
                      @name="destination"
                      @onSet={{fn this.setMapping "destination"}}
                      @showTitle={{false}}
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
                      @showTitle={{false}}
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
                    {{#let
                      (get this.previewByField mapping.destination)
                      as |preview|
                    }}
                      {{#if preview}}
                        <div
                          class="salesforce-guided-sync__mapping-preview"
                          data-test-preview-field={{mapping.destination}}
                        >
                          <span
                            class="salesforce-guided-sync__preview-origin"
                            role="img"
                            aria-label={{preview.originLabel}}
                          >{{dIcon preview.originIcon}}</span>
                          <div
                            class="salesforce-guided-sync__mapping-preview-value"
                          >
                            <span
                              class="salesforce-guided-sync__preview-mobile-label"
                            >{{i18n
                                "salesforce.guided_sync.preview_title"
                              }}</span>
                            <span>{{preview.result}}</span>
                            {{#if preview.showPrevious}}
                              <small>
                                {{i18n "salesforce.guided_sync.previous_value"}}
                                <del>{{preview.current}}</del>
                              </small>
                            {{/if}}
                          </div>
                        </div>
                      {{else}}
                        <span
                          class="salesforce-guided-sync__mapping-preview-empty"
                        >—</span>
                      {{/if}}
                    {{/let}}
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
              {{#if this.error}}
                <form.Alert
                  @type="error"
                  @icon="triangle-exclamation"
                >{{this.error}}</form.Alert>
              {{/if}}
              {{#if this.previewError}}
                <form.Alert @type="error">{{this.previewError}}</form.Alert>
                <DButton
                  class="btn-flat"
                  data-test-retry-preview
                  @action={{this.loadPreview}}
                  @label="salesforce.guided_sync.retry_fields"
                />
              {{/if}}
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
            @disabled={{this.saveDisabled}}
            @label={{this.submitLabel}}
          />
        </form.Actions>
      </Form>

    </div>
  </template>
}
