import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AdminConfigAreaCard from "discourse/admin/components/admin-config-area-card";
import Form from "discourse/components/form";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import { ajax } from "discourse/lib/ajax";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import SalesforceFieldMenu from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-field-menu";
import {
  buildPreview,
  createDemoConfiguration,
  DEMO_SOURCES,
  mappingError,
  normalizeConfiguration,
  updateMapping,
} from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-demo";

const PREFIX = "salesforce.guided_sync";

export default class SalesforceGuidedSync extends Component {
  @service a11y;

  @tracked configuration = normalizeConfiguration(
    this.args.record || createDemoConfiguration()
  );
  @tracked enabled = false;
  @tracked message;
  @tracked step = 1;
  @tracked saving = false;
  @tracked salesforceFields = [];
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

  get title() {
    return this.configuration.name || i18n(`${PREFIX}.title`);
  }

  get groups() {
    return (this.args.groups || []).map((group) => ({
      ...group,
      label: Number.isInteger(group.user_count)
        ? i18n(`${PREFIX}.group_option`, {
            name: group.name,
            count: group.user_count,
          })
        : group.name,
    }));
  }

  get group() {
    return this.groups.find((group) => group.name === this.configuration.group);
  }

  get backfillLabel() {
    const count = this.group?.user_count;
    return Number.isInteger(count)
      ? i18n(`${PREFIX}.backfill`, { count })
      : i18n(`${PREFIX}.backfill_without_count`);
  }

  get fields() {
    return this.salesforceFields.filter((field) => field.id !== "Email");
  }

  get sources() {
    return DEMO_SOURCES.map((source) => ({
      ...source,
      label: i18n(`${PREFIX}.sources.${source.id}`),
    }));
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
    const error = mappingError(this.configuration, this.salesforceFields);
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
      !this.group ||
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

  get currentStepNumber() {
    return this.step;
  }

  get submitLabel() {
    return this.step === 4
      ? `${PREFIX}.${this.enabled ? "save_changes" : "enable"}`
      : `${PREFIX}.continue`;
  }

  get preview() {
    return buildPreview(this.configuration, "alex").map((row) => ({
      ...row,
      outcomeLabel: i18n(`${PREFIX}.outcomes.${row.outcome}`),
      kept: row.outcome === "kept",
    }));
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
  allowNavigation() {
    return false;
  }

  @action
  goToStep(index) {
    this.message = null;
    this.step = index;
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
      <DPageSubheader
        @descriptionLabel={{i18n "salesforce.guided_sync.description"}}
        @titleLabel={{this.title}}
      />

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
              {{#if @onSave}}
                <form.Field
                  @name="name"
                  @onSet={{this.setConfiguration}}
                  @title={{i18n "salesforce.guided_sync.configuration_name"}}
                  @type="input"
                  @validation="required"
                  as |field|
                >
                  <field.Control @maxlength={{60}} />
                </form.Field>
              {{/if}}
              <form.Field
                @name="group"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.group"}}
                @type="select"
                @validation="required"
                as |field|
              >
                <field.Control @includeNone={{true}} as |select|>
                  {{#each this.groups as |group|}}
                    <select.Option
                      @value={{group.name}}
                    >{{group.label}}</select.Option>
                  {{/each}}
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
              <form.Alert @icon="circle-info">
                {{i18n "salesforce.guided_sync.matching_help"}}
              </form.Alert>
            </:content>
          </AdminConfigAreaCard>
        {{else if (eq this.step 2)}}
          <h3 class="salesforce-guided-sync__section-title">{{i18n
              "salesforce.guided_sync.mapping_title"
            }}</h3>
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
                        @name="source"
                        @showTitle={{false}}
                        @onSet={{fn this.setMapping "source"}}
                        @title={{i18n "salesforce.guided_sync.discourse_field"}}
                        @type="select"
                        @validation="required"
                        as |field|
                      >
                        <field.Control
                          aria-label={{i18n
                            "salesforce.guided_sync.discourse_field"
                          }}
                          @includeNone={{false}}
                          as |select|
                        >
                          <select.Option @value="">{{i18n
                              "salesforce.guided_sync.choose_source"
                            }}</select.Option>
                          {{#each this.sources as |source|}}
                            <select.Option
                              @value={{source.id}}
                            >{{source.label}}</select.Option>
                          {{/each}}
                        </field.Control>
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
        {{else if (eq this.step 3)}}
          <AdminConfigAreaCard
            class="salesforce-guided-sync__form-card"
            @heading="salesforce.guided_sync.behavior_title"
            @description="salesforce.guided_sync.behavior_description"
          >
            <:content>
              <form.Field
                @name="onJoin"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.on_join"}}
                @type="checkbox"
                as |field|
              >
                <field.Control />
              </form.Field>
              <form.Field
                @name="onChange"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.on_change"}}
                @type="checkbox"
                as |field|
              >
                <field.Control />
              </form.Field>
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
                @helpText={{i18n "salesforce.guided_sync.schedule_help"}}
                @name="schedule"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.schedule"}}
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
          <h3 class="salesforce-guided-sync__section-title">{{i18n
              "salesforce.guided_sync.review_title"
            }}</h3>
          <p class="salesforce-guided-sync__description">{{i18n
              "salesforce.guided_sync.review_description"
            }}</p>
          <div class="salesforce-guided-sync__preview-table">
            <table class="d-table">
              <thead class="d-table__header"><tr>
                  <th>{{i18n "salesforce.guided_sync.salesforce_field"}}</th>
                  <th>{{i18n "salesforce.guided_sync.current_value"}}</th>
                  <th>{{i18n "salesforce.guided_sync.discourse_value"}}</th>
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
                      >{{i18n "salesforce.guided_sync.after_sync"}}</div>
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
        {{/if}}

        <form.Actions class="salesforce-guided-sync__footer">
          <p class="salesforce-guided-sync__help">{{i18n
              "salesforce.guided_sync.step_progress"
              current=this.currentStepNumber
              total=this.steps.length
            }}</p>
          {{#if @onCancel}}
            <DButton
              class="btn-flat"
              data-test-configurations-back
              @action={{@onCancel}}
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
