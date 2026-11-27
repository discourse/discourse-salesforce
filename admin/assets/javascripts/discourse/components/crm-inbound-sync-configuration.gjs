import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { cancel, next } from "@ember/runloop";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import CrmPullMappings from "discourse/plugins/discourse-salesforce/discourse/components/crm-pull-mappings";
import SyncConfigurationHeading from "discourse/plugins/discourse-salesforce/discourse/components/sync-configuration-heading";
import {
  createPullConfiguration,
  pullTarget,
  pullTargetLabel,
} from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PREFIX = "salesforce.guided_sync.pull";
const FORM_ONLY = ["target", "pull_mappings"];

function emptyList() {
  return { items: [], loaded: false, loading: false, error: null };
}

function row(id, mapping = {}) {
  return {
    id,
    source: mapping.source || "",
    destination: mapping.destination || "",
    policy: mapping.policy || "overwrite",
  };
}

function formConfiguration(record) {
  const configuration = structuredClone(record);
  configuration.target = `${record.provider}:${record.object}`;
  configuration.pull_mappings = record.mappings.map((mapping, index) =>
    row(index + 1, mapping)
  );
  return configuration;
}

// Pulls one CRM object into Discourse.
export default class CrmInboundSyncConfiguration extends Component {
  @service a11y;
  @service dialog;

  @tracked
  configuration = formConfiguration(
    this.args.record ||
      createPullConfiguration(
        this.args.targets?.find((target) => !target.configured)
      )
  );
  @tracked fields = emptyList();
  @tracked destinations = [];
  @tracked saving = false;
  @tracked
  hasCustomName = Boolean(
    this.configuration.name && this.configuration.name !== this.defaultTitle
  );
  formData = this.configuration;

  #form;
  // The row a refused save pointed at; any row edit can resolve it or shift its index.
  #savedMappingErrorPath;
  #initialLoad;
  #fieldsRequest = 0;

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this.#initialLoad);
  }

  get target() {
    return pullTarget(this.configuration.provider, this.configuration.object);
  }

  get defaultTitle() {
    return i18n(`${PREFIX}.default_names.${this.target.translationKey}`);
  }

  get title() {
    return this.hasCustomName ? this.configuration.name : this.defaultTitle;
  }

  get targetDescription() {
    return i18n(this.target.description || `${PREFIX}.what_description`);
  }

  get targets() {
    return (this.args.targets || []).map((target) => {
      const label = pullTargetLabel(target.provider, target.object);
      return {
        ...target,
        id: `${target.provider}:${target.object}`,
        label: target.configured
          ? `${label} (${i18n(`${PREFIX}.already_configured`)})`
          : label,
      };
    });
  }

  get selectedTargetLabel() {
    return pullTargetLabel(
      this.configuration.provider,
      this.configuration.object
    );
  }

  get scheduleTiming() {
    return i18n(`${PREFIX}.schedule_timing.${this.configuration.schedule}`);
  }

  get submitLabel() {
    return !this.args.record?.id && this.configuration.backfill
      ? `${PREFIX}.save_and_pull`
      : "salesforce.guided_sync.save_changes";
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
    this.#initialLoad = next(this, () => this.refreshFields());
  }

  @action
  async refreshFields(force = false) {
    const { provider, object } = this.configuration;
    const request = ++this.#fieldsRequest;
    const outdated = () =>
      this.isDestroying ||
      this.isDestroyed ||
      request !== this.#fieldsRequest ||
      provider !== this.configuration.provider ||
      object !== this.configuration.object;
    this.fields = { ...this.fields, loading: true, error: null };
    try {
      const result = await ajax(this.target.metadataUrl, {
        data: { object, direction: "inbound", refresh: force },
      });
      if (outdated()) {
        return;
      }
      this.destinations = result.destinations || [];
      if (!this.args.record?.id) {
        this.#dropUnavailableDestinations();
      }
      this.fields = {
        ...emptyList(),
        // The server gives every field the generic type that decides where it can be copied.
        items: this.target.fields(result).map((field) => ({
          id: field.name,
          label: field.label || field.name,
          type: field.source_type,
          custom: field.custom,
        })),
        loaded: true,
      };
      this.#form.removeError("pull_mappings");
    } catch (error) {
      if (!outdated()) {
        this.fields = {
          ...emptyList(),
          error: extractError(
            error,
            i18n("salesforce.guided_sync.fields_failed")
          ),
        };
      }
    }
  }

  @action
  setRows(pullMappings) {
    if (this.#savedMappingErrorPath) {
      this.#form.removeError(this.#savedMappingErrorPath);
      this.#savedMappingErrorPath = null;
    }
    this.#form.set("pull_mappings", pullMappings);
    this.configuration = {
      ...this.configuration,
      pull_mappings: pullMappings,
    };
  }

  @action
  setConfiguration(value, { name, set }) {
    set(name, value);
    this.configuration = { ...this.configuration, [name]: value };
  }

  @action
  selectTarget(value, { set }) {
    const target = this.targets.find((item) => item.id === value);
    if (!target || target.configured) {
      return;
    }
    set("target", value);
    const created = formConfiguration({
      ...createPullConfiguration(target),
      schedule: this.configuration.schedule,
      backfill: this.configuration.backfill,
    });
    for (const name of ["provider", "object", "kind", "pull_mappings"]) {
      this.#form.set(name, created[name]);
    }
    this.configuration = { ...this.configuration, ...created };
    this.fields = emptyList();
    this.destinations = [];
    this.refreshFields();
  }

  @action
  validateConfiguration(data, { addError, removeError }) {
    removeError("pull_mappings");
    const fields = this.fields;
    if (
      data.pull_mappings.length &&
      (fields.error || fields.loading || !fields.loaded)
    ) {
      addError("pull_mappings", {
        title: i18n(`${PREFIX}.mapping_title`),
        message: fields.error || i18n(`${PREFIX}.loading_fields`),
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
      const result = await this.args.onSave(this.#payload());
      if (result === true) {
        this.a11y.announce(i18n("salesforce.guided_sync.save_success"));
      } else if (result?.mappingError) {
        const { index, message } = result.mappingError;
        this.#savedMappingErrorPath = `pull_mappings.${index}.destination`;
        this.#form.addError(this.#savedMappingErrorPath, {
          title: i18n("salesforce.guided_sync.discourse_field"),
          message,
        });
      }
    } finally {
      this.saving = false;
    }
  }

  @action
  cancelSetup() {
    this.dialog.confirm({
      title: i18n("salesforce.guided_sync.cancel_title"),
      message: i18n("salesforce.guided_sync.cancel_message"),
      confirmButtonLabel: "salesforce.guided_sync.discard_changes",
      confirmButtonClass: "btn-danger",
      cancelButtonLabel: "salesforce.guided_sync.keep_editing",
      didConfirm: () => this.args.onCancel(),
    });
  }

  @action
  allowNavigation() {
    return false;
  }

  #payload() {
    const configuration = { ...this.configuration };
    const pullMappings = configuration.pull_mappings;
    for (const formOnly of FORM_ONLY) {
      delete configuration[formOnly];
    }
    const mappings = pullMappings.map(
      ({ source, destination, policy }, index) => ({
        id: index + 1,
        object: configuration.object,
        source,
        ...(destination ? { destination, policy } : {}),
      })
    );
    return { ...configuration, name: this.title, mappings };
  }

  // A default row can name a field this site cannot fill, such as a name set by the login provider.
  #dropUnavailableDestinations() {
    const offered = new Set(this.destinations.map(({ id }) => id));
    this.setRows(
      this.configuration.pull_mappings.map((pullMapping) =>
        pullMapping.destination && !offered.has(pullMapping.destination)
          ? { ...pullMapping, destination: "" }
          : pullMapping
      )
    );
  }

  <template>
    <div
      class="crm-pull-configuration admin-config-page__main-area"
      ...attributes
    >
      <SyncConfigurationHeading
        class="crm-pull-configuration__heading"
        @editable={{@onSave}}
        @onApply={{this.applyName}}
        @title={{this.title}}
      />
      <p>{{i18n "salesforce.guided_sync.pull.description"}}</p>

      <Form
        class="crm-pull-configuration__form"
        @data={{this.formData}}
        @onDirtyCheck={{this.allowNavigation}}
        @onRegisterApi={{this.registerForm}}
        @onSubmit={{this.save}}
        @validate={{this.validateConfiguration}}
        @validateOn="submit"
        as |form|
      >
        <section
          class="crm-pull-configuration__section"
          aria-labelledby="crm-pull-what-title"
        >
          <h3 id="crm-pull-what-title">{{i18n
              "salesforce.guided_sync.pull.what_title"
            }}</h3>
          <p
            class="crm-pull-configuration__description"
            data-test-pull-description
          >{{this.targetDescription}}</p>
          <div class="crm-pull-configuration__pull-fields">
            <form.Field
              @disabled={{@record.id}}
              @name="target"
              @onSet={{this.selectTarget}}
              @title={{i18n "salesforce.guided_sync.pull_target"}}
              @type="menu"
              @validation="required"
              as |field|
            >
              <field.Control @selection={{this.selectedTargetLabel}} as |menu|>
                {{#each this.targets key="id" as |target|}}
                  <menu.Item
                    data-test-pull-target={{target.id}}
                    disabled={{target.configured}}
                    @value={{target.id}}
                  >{{target.label}}</menu.Item>
                {{/each}}
              </field.Control>
            </form.Field>
          </div>
        </section>
        <section
          class="crm-pull-configuration__section"
          aria-labelledby="crm-pull-behavior-title"
        >
          <h3 id="crm-pull-behavior-title">{{i18n
              "salesforce.guided_sync.pull.behavior_title"
            }}</h3>
          {{#unless this.target.storeOnly}}
            <p
              class="crm-pull-configuration__description"
              data-test-user-pull-note
            >{{i18n "salesforce.guided_sync.pull.user_pull_note"}}</p>
          {{/unless}}
          <div class="crm-pull-configuration__behavior-fields">
            <form.Field
              @format="full"
              @name="backfill"
              @onSet={{this.setConfiguration}}
              @title={{i18n "salesforce.guided_sync.pull.backfill"}}
              @type="checkbox"
              as |field|
            >
              <field.Control />
            </form.Field>
            <form.Field
              @format="full"
              @helpText={{this.scheduleTiming}}
              @name="schedule"
              @onSet={{this.setConfiguration}}
              @title={{i18n "salesforce.guided_sync.pull.schedule"}}
              @tooltip={{i18n "salesforce.guided_sync.pull.schedule_help"}}
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
          class="crm-pull-configuration__section"
          aria-labelledby="crm-pull-mapping-title"
        >
          <h3 id="crm-pull-mapping-title">{{i18n
              "salesforce.guided_sync.pull.mapping_title"
            }}</h3>
          <p class="crm-pull-configuration__description">{{i18n
              "salesforce.guided_sync.pull.mapping_description"
            }}</p>
          <CrmPullMappings
            @destinations={{this.destinations}}
            @emailField={{this.target.emailField}}
            @error={{this.fields.error}}
            @fields={{this.fields.items}}
            @form={{form}}
            @loading={{this.fields.loading}}
            @name="pull_mappings"
            @onChange={{this.setRows}}
            @onRefresh={{this.refreshFields}}
            @providerName={{this.target.name}}
            @rows={{this.configuration.pull_mappings}}
            @storeOnly={{this.target.storeOnly}}
          />
        </section>
        <form.Actions class="crm-pull-configuration__footer">
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
