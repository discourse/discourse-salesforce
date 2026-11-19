import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { cancel, next } from "@ember/runloop";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DMultiSelect from "discourse/ui-kit/d-multi-select";
import { i18n } from "discourse-i18n";
import SyncConfigurationHeading from "discourse/plugins/discourse-salesforce/discourse/components/sync-configuration-heading";
import hubspotProvider from "discourse/plugins/discourse-salesforce/discourse/lib/hubspot/sync-provider";
import { createHubspotSyncConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PREFIX = "salesforce.guided_sync.hubspot";
const OBJECTS = [
  {
    key: "contact",
    field: "contact_properties",
    title: `${PREFIX}.properties`,
    help: `${PREFIX}.properties_help`,
    label: `${PREFIX}.choose_properties`,
    refresh: `${PREFIX}.refresh_properties`,
  },
  {
    key: "company",
    field: "company_properties",
    toggle: "pull_companies",
    enable: `${PREFIX}.pull_companies`,
    enableHelp: `${PREFIX}.pull_companies_help`,
    title: `${PREFIX}.company_properties`,
    help: `${PREFIX}.company_properties_help`,
    label: `${PREFIX}.choose_company_properties`,
    refresh: `${PREFIX}.refresh_company_properties`,
  },
];
const COMING_SOON_OBJECTS = [
  { value: "Contact", label: "salesforce_contact" },
  { value: "Lead", label: "salesforce_lead" },
];

function emptyList() {
  return { properties: [], loaded: false, loading: false, error: null };
}

function splitMappings(record) {
  const configuration = structuredClone(record);
  for (const object of OBJECTS) {
    configuration[object.field] = configuration.mappings
      .filter((mapping) => mapping.object === object.key)
      .map((mapping) => mapping.source);
    if (object.toggle) {
      configuration[object.toggle] = configuration[object.field].length > 0;
    }
  }
  return configuration;
}

export default class HubspotSyncConfiguration extends Component {
  @service a11y;
  @service dialog;

  @tracked configuration = splitMappings(
    this.args.record || createHubspotSyncConfiguration()
  );
  @tracked lists = { contact: emptyList(), company: emptyList() };
  @tracked saving = false;
  formData = this.configuration;

  #form;
  #initialLoad;
  #requests = { contact: 0, company: 0 };

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this.#initialLoad);
  }

  get title() {
    return this.configuration.name || i18n(`${PREFIX}.default_name`);
  }

  get comingSoonObjects() {
    return COMING_SOON_OBJECTS.map((object) => ({
      value: object.value,
      label: i18n("salesforce.guided_sync.coming_soon", {
        name: i18n(`salesforce.guided_sync.pull_objects.${object.label}`),
      }),
    }));
  }

  get objectLabel() {
    return i18n("salesforce.guided_sync.pull_objects.hubspot_contact");
  }

  get objects() {
    return OBJECTS.map((object) => ({
      ...object,
      enabled: !object.toggle || this.configuration[object.toggle],
      list: this.lists[object.key],
      selection: this.configuration[object.field].map(
        (source) =>
          this.lists[object.key].properties.find(
            (property) => property.name === source
          ) || { name: source, label: source }
      ),
    }));
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
    this.configuration = { ...this.configuration, name: value };
  }

  @action
  registerForm(form) {
    this.#form = form;
    this.#initialLoad = next(this, () => {
      for (const object of this.objects) {
        if (object.enabled) {
          this.refreshProperties(object.key);
        }
      }
    });
  }

  @action
  async refreshProperties(key, force = false) {
    const request = ++this.#requests[key];
    const field = OBJECTS.find((object) => object.key === key).field;
    this.#updateList(key, { loading: true, error: null });
    try {
      const result = await ajax(hubspotProvider.metadataUrl, {
        data: { object: key, refresh: force },
      });
      if (this.#stale(key, request)) {
        return;
      }
      this.#updateList(key, { properties: result.properties, loaded: true });
      this.#form.removeError(field);
    } catch (error) {
      if (!this.#stale(key, request)) {
        this.#updateList(key, {
          error: extractError(error, i18n(`${PREFIX}.properties_failed`)),
        });
      }
    } finally {
      if (!this.#stale(key, request)) {
        this.#updateList(key, { loading: false });
      }
    }
  }

  @action
  async findProperties(key, query) {
    const term = (query || "").toLowerCase();
    return this.lists[key].properties.filter(
      (property) =>
        property.name.toLowerCase().includes(term) ||
        property.label?.toLowerCase().includes(term)
    );
  }

  @action
  compareProperties(a, b) {
    return a.name === b.name;
  }

  @action
  selectProperties(key, properties) {
    const field = OBJECTS.find((object) => object.key === key).field;
    const sources = properties.map((property) => property.name);
    this.#form.set(field, sources);
    this.configuration = { ...this.configuration, [field]: sources };
  }

  @action
  setConfiguration(value, { name, set }) {
    set(name, value);
    this.configuration = { ...this.configuration, [name]: value };
  }

  @action
  toggleObject(key, value, options) {
    this.setConfiguration(value, options);
    if (value && !this.lists[key].loaded) {
      this.refreshProperties(key);
    }
  }

  @action
  validateConfiguration(data, { addError, removeError }) {
    for (const object of OBJECTS) {
      removeError(object.field);
      const list = this.lists[object.key];
      if (
        (object.toggle && !data[object.toggle]) ||
        data[object.field].length === 0
      ) {
        continue;
      }
      if (list.error || list.loading) {
        addError(object.field, {
          title: i18n(object.title),
          message: list.error || i18n(`${PREFIX}.loading_properties`),
        });
        continue;
      }
      const unavailable = data[object.field].filter(
        (source) =>
          !list.properties.some((property) => property.name === source)
      );
      if (unavailable.length) {
        addError(object.field, {
          title: i18n(object.title),
          message: i18n(`${PREFIX}.properties_unavailable`, {
            properties: unavailable.join(", "),
          }),
        });
      }
    }
  }

  @action
  async save() {
    if (this.saving || !this.args.onSave) {
      return;
    }
    this.saving = true;
    try {
      if (await this.args.onSave(this.#payload())) {
        this.a11y.announce(i18n("salesforce.guided_sync.save_success"));
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
    const mappings = this.objects
      .flatMap((object) =>
        object.enabled
          ? configuration[object.field].map((source) => ({
              object: object.key,
              source,
            }))
          : []
      )
      .map((mapping, index) => ({ id: index + 1, ...mapping }));
    for (const object of OBJECTS) {
      delete configuration[object.field];
      delete configuration[object.toggle];
    }
    return { ...configuration, mappings };
  }

  #stale(key, request) {
    return (
      this.isDestroying || this.isDestroyed || request !== this.#requests[key]
    );
  }

  #updateList(key, patch) {
    this.lists = { ...this.lists, [key]: { ...this.lists[key], ...patch } };
  }

  <template>
    <div
      class="hubspot-sync-configuration admin-config-page__main-area"
      ...attributes
    >
      <SyncConfigurationHeading
        class="hubspot-sync-configuration__heading"
        @editable={{@onSave}}
        @onApply={{this.applyName}}
        @title={{this.title}}
      />
      <p>{{i18n "salesforce.guided_sync.hubspot.description"}}</p>

      <Form
        class="hubspot-sync-configuration__form"
        @data={{this.formData}}
        @onDirtyCheck={{this.allowNavigation}}
        @onRegisterApi={{this.registerForm}}
        @onSubmit={{this.save}}
        @validate={{this.validateConfiguration}}
        @validateOn="submit"
        as |form|
      >
        <section
          class="hubspot-sync-configuration__section"
          aria-labelledby="hubspot-pull-title"
        >
          <h3 id="hubspot-pull-title">{{i18n
              "salesforce.guided_sync.hubspot.pull_title"
            }}</h3>
          <p class="hubspot-sync-configuration__description">{{i18n
              "salesforce.guided_sync.hubspot.pull_description"
            }}</p>
          <div class="hubspot-sync-configuration__pull-fields">
            <form.Field
              @disabled={{@record.id}}
              @name="object"
              @title={{i18n "salesforce.guided_sync.pull_target"}}
              @type="menu"
              @validation="required"
              as |field|
            >
              <field.Control @selection={{this.objectLabel}} as |menu|>
                <menu.Item @value="contact">{{this.objectLabel}}</menu.Item>
                {{#each this.comingSoonObjects as |object|}}
                  <menu.Item
                    data-test-coming-soon-object={{object.value}}
                    disabled={{true}}
                    @value={{object.value}}
                  >{{object.label}}</menu.Item>
                {{/each}}
              </field.Control>
            </form.Field>
            {{#each this.objects as |object|}}
              {{#if object.toggle}}
                <form.Field
                  @format="full"
                  @helpText={{i18n object.enableHelp}}
                  @name={{object.toggle}}
                  @onSet={{fn this.toggleObject object.key}}
                  @title={{i18n object.enable}}
                  @type="checkbox"
                  as |field|
                >
                  <field.Control />
                </form.Field>
              {{/if}}
              {{#if object.enabled}}
                <DConditionalLoadingSpinner
                  class="hubspot-sync-configuration__object-properties"
                  data-test-properties-loading={{object.key}}
                  aria-busy={{object.list.loading}}
                  @condition={{object.list.loading}}
                >
                  {{#if object.list.error}}
                    <form.Alert @type="error">{{object.list.error}}</form.Alert>
                    <DButton
                      class="btn-default"
                      data-test-refresh-properties={{object.key}}
                      @action={{fn this.refreshProperties object.key true}}
                      @icon="arrows-rotate"
                      @label="salesforce.guided_sync.retry_fields"
                    />
                  {{else}}
                    <form.Field
                      @format="full"
                      @helpText={{i18n object.help}}
                      @name={{object.field}}
                      @title={{i18n object.title}}
                      @type="custom"
                      as |field|
                    >
                      <field.Control>
                        <div class="hubspot-sync-configuration__properties">
                          <DMultiSelect
                            @compareFn={{this.compareProperties}}
                            @label={{i18n object.label}}
                            @loadFn={{fn this.findProperties object.key}}
                            @matchTriggerWidth={{true}}
                            @onChange={{fn this.selectProperties object.key}}
                            @selection={{object.selection}}
                          >
                            <:selection
                              as |property|
                            >{{property.label}}</:selection>
                            <:result as |property|>
                              <span
                                class="hubspot-sync-configuration__property"
                              >{{property.label}}
                                <code>{{property.name}}</code></span>
                            </:result>
                          </DMultiSelect>
                        </div>
                      </field.Control>
                    </form.Field>
                    <DButton
                      class="btn-flat"
                      data-test-refresh-properties={{object.key}}
                      @action={{fn this.refreshProperties object.key true}}
                      @disabled={{object.list.loading}}
                      @icon="arrows-rotate"
                      @label={{object.refresh}}
                    />
                  {{/if}}
                </DConditionalLoadingSpinner>
              {{/if}}
            {{/each}}
          </div>
        </section>
        <section
          class="hubspot-sync-configuration__section"
          aria-labelledby="hubspot-behavior-title"
        >
          <h3 id="hubspot-behavior-title">{{i18n
              "salesforce.guided_sync.hubspot.behavior_title"
            }}</h3>
          <p
            class="hubspot-sync-configuration__description"
            data-test-user-pull-note
          >{{i18n "salesforce.guided_sync.hubspot.user_pull_note"}}</p>
          <div class="hubspot-sync-configuration__behavior-fields">
            <form.Field
              @format="full"
              @name="backfill"
              @onSet={{this.setConfiguration}}
              @title={{i18n "salesforce.guided_sync.hubspot.backfill"}}
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
              @title={{i18n "salesforce.guided_sync.hubspot.schedule"}}
              @tooltip={{i18n "salesforce.guided_sync.hubspot.schedule_help"}}
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
        <form.Actions class="hubspot-sync-configuration__footer">
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
