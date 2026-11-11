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
import { createHubspotSyncConfiguration } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PREFIX = "salesforce.guided_sync.hubspot";

export default class HubspotSyncConfiguration extends Component {
  @service a11y;
  @service dialog;

  @tracked configuration = structuredClone(
    this.args.record || createHubspotSyncConfiguration()
  );
  @tracked loadingProperties = false;
  @tracked properties = [];
  @tracked propertiesError;
  @tracked saving = false;
  formData = this.configuration;

  #form;
  #initialLoad;
  #propertiesRequest = 0;

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this.#initialLoad);
  }

  get title() {
    return this.configuration.name || i18n(`${PREFIX}.default_name`);
  }

  get selectedProperties() {
    return this.configuration.mappings.map(
      (mapping) =>
        this.properties.find(
          (property) => property.name === mapping.source
        ) || { name: mapping.source, label: mapping.source }
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
    this.configuration = { ...this.configuration, name: value };
  }

  @action
  registerForm(form) {
    this.#form = form;
    this.#initialLoad = next(this, () => {
      this.refreshProperties();
    });
  }

  @action
  async refreshProperties(force = false) {
    const request = ++this.#propertiesRequest;
    this.loadingProperties = true;
    this.propertiesError = null;
    try {
      const result = await ajax(
        "/salesforce/admin/hubspot/contact-properties.json",
        { data: { refresh: force } }
      );
      if (this.#stale(request)) {
        return;
      }
      this.properties = result.properties;
      this.#form.removeError("mappings");
    } catch (error) {
      if (!this.#stale(request)) {
        this.propertiesError = (error.jqXHR || error).responseJSON?.errors
          ?.length
          ? extractError(error)
          : i18n(`${PREFIX}.properties_failed`);
      }
    } finally {
      if (!this.#stale(request)) {
        this.loadingProperties = false;
      }
    }
  }

  @action
  async findProperties(query) {
    const term = (query || "").toLowerCase();
    return this.properties.filter(
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
  selectProperties(properties) {
    const mappings = properties.map((property, index) => ({
      id: index + 1,
      source: property.name,
    }));
    this.#form.set("mappings", mappings);
    this.configuration = { ...this.configuration, mappings };
  }

  @action
  setConfiguration(value, { name, set }) {
    set(name, value);
    this.configuration = { ...this.configuration, [name]: value };
  }

  @action
  validateConfiguration(data, { addError, removeError }) {
    removeError("mappings");
    if (this.propertiesError || this.loadingProperties) {
      addError("mappings", {
        title: i18n(`${PREFIX}.properties`),
        message: this.propertiesError || i18n(`${PREFIX}.loading_properties`),
      });
      return;
    }
    const unavailable = data.mappings
      .map((mapping) => mapping.source)
      .filter(
        (source) =>
          !this.properties.some((property) => property.name === source)
      );
    if (unavailable.length) {
      addError("mappings", {
        title: i18n(`${PREFIX}.properties`),
        message: i18n(`${PREFIX}.properties_unavailable`, {
          properties: unavailable.join(", "),
        }),
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

  #stale(request) {
    return (
      this.isDestroying ||
      this.isDestroyed ||
      request !== this.#propertiesRequest
    );
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
          <DConditionalLoadingSpinner
            data-test-properties-loading
            aria-busy={{this.loadingProperties}}
            @condition={{this.loadingProperties}}
          >
            {{#if this.propertiesError}}
              <form.Alert @type="error">{{this.propertiesError}}</form.Alert>
              <DButton
                class="btn-default hubspot-sync-configuration__retry-properties"
                data-test-refresh-properties
                @action={{fn this.refreshProperties true}}
                @icon="arrows-rotate"
                @label="salesforce.guided_sync.retry_fields"
              />
            {{else}}
              <form.Field
                @format="full"
                @helpText={{i18n
                  "salesforce.guided_sync.hubspot.properties_help"
                }}
                @name="mappings"
                @title={{i18n "salesforce.guided_sync.hubspot.properties"}}
                @type="custom"
                as |field|
              >
                <field.Control>
                  <div class="hubspot-sync-configuration__properties">
                    <DMultiSelect
                      @compareFn={{this.compareProperties}}
                      @label={{i18n
                        "salesforce.guided_sync.hubspot.choose_properties"
                      }}
                      @loadFn={{this.findProperties}}
                      @matchTriggerWidth={{true}}
                      @onChange={{this.selectProperties}}
                      @selection={{this.selectedProperties}}
                    >
                      <:selection as |property|>{{property.label}}</:selection>
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
                data-test-refresh-properties
                @action={{fn this.refreshProperties true}}
                @disabled={{this.loadingProperties}}
                @icon="arrows-rotate"
                @label="salesforce.guided_sync.hubspot.refresh_properties"
              />
            {{/if}}
          </DConditionalLoadingSpinner>
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
