import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AdminConfigAreaCard from "discourse/admin/components/admin-config-area-card";
import Form from "discourse/components/form";
import { and, eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import SalesforceConnectionSummary from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-connection-summary";
import SalesforceFieldMenu from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-field-menu";
import {
  buildPreview,
  createDemoConfiguration,
  DEMO_FIELDS,
  DEMO_GROUPS,
  DEMO_SOURCES,
  DEMO_USERS,
  destinationName,
  mappingError,
  updateMapping,
} from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-demo";

const PREFIX = "salesforce.guided_sync";

export default class SalesforceGuidedSync extends Component {
  @service a11y;

  @tracked configuration = structuredClone(
    this.args.record || createDemoConfiguration()
  );
  @tracked connected = Boolean(this.args.connection);
  @tracked formData = this.configuration;
  @tracked enabled = false;
  @tracked message;
  @tracked sample = "alex";
  @tracked step = this.args.connection ? 1 : 0;
  @tracked saving = false;

  #form;
  #nextMappingId =
    Math.max(
      0,
      ...this.configuration.mappings.map((mapping) => Number(mapping.id))
    ) + 1;

  get title() {
    return this.configuration.name || i18n(`${PREFIX}.title`);
  }

  get generatedWorkflows() {
    return (this.args.record?.workflows || []).map((workflow) => ({
      ...workflow,
      url: `/admin/plugins/discourse-workflows/workflows/${workflow.id}`,
      executionUrl: `/admin/plugins/discourse-workflows/workflows/${workflow.id}/executions`,
    }));
  }

  get groups() {
    return DEMO_GROUPS.map((group) => ({
      ...group,
      label: i18n(`${PREFIX}.group_option`, {
        name: group.id,
        count: group.count,
      }),
    }));
  }

  get group() {
    return DEMO_GROUPS.find((group) => group.id === this.configuration.group);
  }

  get fields() {
    return DEMO_FIELDS.map((field) => ({
      ...field,
      label: destinationName(field.id, this.configuration.object),
    }));
  }

  get sources() {
    return DEMO_SOURCES.map((source) => ({
      ...source,
      label: i18n(`${PREFIX}.sources.${source.id}`),
    }));
  }

  get users() {
    return DEMO_USERS.map((user) => ({
      ...user,
      label: i18n(`${PREFIX}.sample_option`, {
        name: user.name,
        state: i18n(
          `${PREFIX}.${user.existing ? "existing_record" : "new_record"}`
        ),
      }),
    }));
  }

  get steps() {
    return ["connect", "scope", "mapping", "behavior", "review"]
      .map((id, index) => ({
        id,
        index,
        number: index + (this.args.connection ? 0 : 1),
        label: i18n(`${PREFIX}.steps.${id}`),
        current: this.step === index,
        completed: this.step > index,
        disabled: index > 0 && !this.connected,
      }))
      .filter((step) => !this.args.connection || step.id !== "connect");
  }

  get error() {
    const error = mappingError(this.configuration);
    return error ? i18n(`${PREFIX}.errors.${error}`) : null;
  }

  get continueDisabled() {
    return (
      this.saving || !this.connected || (this.step >= 2 && Boolean(this.error))
    );
  }

  get canGoBack() {
    return this.step > (this.args.connection ? 1 : 0);
  }

  get currentStepNumber() {
    return this.step + (this.args.connection ? 0 : 1);
  }

  get submitLabel() {
    return this.step === 4
      ? `${PREFIX}.${this.enabled ? "save_changes" : "enable"}`
      : `${PREFIX}.continue`;
  }

  get preview() {
    return buildPreview(this.configuration, this.sample).map((row) => ({
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
      this.step++;
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
      this.a11y.announce(i18n(`${PREFIX}.workflows_saved`));
    } else {
      this.#notify(wasEnabled ? "saved_message" : "enabled_message");
    }
  }

  @action
  allowNavigation() {
    return false;
  }

  @action
  async connect() {
    if (this.args.onConnect) {
      this.saving = true;
      try {
        if (!(await this.args.onConnect(this.configuration.environment))) {
          return;
        }
        this.step = 1;
      } finally {
        this.saving = false;
      }
    }
    this.connected = true;
    this.message = null;
    this.a11y.announce(i18n(`${PREFIX}.connected_message`));
  }

  @action
  goToStep(index) {
    this.message = null;
    this.step = index;
  }

  @action
  previousStep() {
    this.step--;
  }

  @action
  refreshFields() {
    this.#notify("refreshed_message");
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
  restart() {
    this.configuration = {
      ...createDemoConfiguration(),
      name: this.args.record?.name,
      object: this.args.record?.object || "Lead",
    };
    this.formData = this.configuration;
    this.connected = Boolean(this.args.connection);
    this.enabled = false;
    this.message = null;
    this.sample = "alex";
    this.step = this.args.connection ? 1 : 0;
    this.#form = null;
    this.#nextMappingId = 8;
  }

  @action
  setConfiguration(value, { name, set }) {
    set(name, value);
    this.configuration = { ...this.configuration, [name]: value };
    if (name === "environment") {
      this.connected = false;
    }
  }

  @action
  setMapping(property, value, { index }) {
    this.#setMappings(
      updateMapping(this.configuration, index, property, value)
    );
  }

  @action
  setSample(value, { name, set }) {
    set(name, value);
    this.sample = value;
    this.configuration = { ...this.configuration, previewUser: value };
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
      >
        <:actions as |actions|>
          <actions.Default
            @action={{this.restart}}
            @label="salesforce.guided_sync.restart"
          />
        </:actions>
      </DPageSubheader>

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
            @disabled={{step.disabled}}
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
        {{#if (eq this.step 0)}}
          <AdminConfigAreaCard
            class="salesforce-guided-sync__form-card"
            @description="salesforce.guided_sync.connect_description"
            @heading="salesforce.guided_sync.connect_title"
          >
            <:content>
              <SalesforceConnectionSummary @connected={{this.connected}} />
              <form.Field
                @name="environment"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.environment"}}
                @type="select"
                @validation="required"
                as |field|
              >
                <field.Control @includeNone={{false}} as |select|>
                  <select.Option @value="sandbox">
                    {{i18n "salesforce.guided_sync.sandbox"}}
                  </select.Option>
                  <select.Option @value="production">
                    {{i18n "salesforce.guided_sync.production"}}
                  </select.Option>
                </field.Control>
              </form.Field>
              {{#unless this.connected}}
                <DButton
                  class="btn-primary"
                  data-test-connect-demo
                  @action={{this.connect}}
                  @disabled={{this.saving}}
                  @label="salesforce.guided_sync.connect"
                />
              {{/unless}}
            </:content>
          </AdminConfigAreaCard>
        {{else if (eq this.step 1)}}
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
                <field.Control @includeNone={{false}} as |select|>
                  {{#each this.groups as |group|}}
                    <select.Option
                      @value={{group.id}}
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
                  <select.Option
                    @value="DiscourseContact__c"
                  >DiscourseContact__c</select.Option>
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
          <p class="salesforce-guided-sync__description">{{i18n
              "salesforce.guided_sync.mapping_description"
            }}</p>
          <div
            class="salesforce-guided-sync__mapping-headings"
            aria-hidden="true"
          >
            <span>{{i18n "salesforce.guided_sync.discourse_field"}}</span>
            <span class="salesforce-guided-sync__arrow-heading"></span>
            <span>{{i18n "salesforce.guided_sync.salesforce_field"}}</span>
            <span>{{i18n "salesforce.guided_sync.existing_value"}}</span>
          </div>
          <div class="salesforce-guided-sync__locked-mapping">
            <span>{{dIcon "lock"}}
              {{i18n "salesforce.guided_sync.email"}}</span>
            <span class="salesforce-guided-sync__mapping-arrow">{{dIcon
                "arrow-right"
              }}</span>
            <code>{{if
                (eq this.configuration.object "DiscourseContact__c")
                "Email__c"
                "Email"
              }}</code>
            <span>{{i18n "salesforce.guided_sync.fixed_mapping"}}</span>
          </div>
          <div class="salesforce-guided-sync__mapping-list">
            <form.Collection @name="mappings" as |collection index mapping|>
              <div
                class="salesforce-guided-sync__mapping-row"
                data-test-mapping={{mapping.id}}
              >
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
                    aria-label={{i18n "salesforce.guided_sync.discourse_field"}}
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
                    aria-label={{i18n "salesforce.guided_sync.existing_value"}}
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
              @action={{this.refreshFields}}
              @icon="arrows-rotate"
              @label="salesforce.guided_sync.refresh_fields"
            />
          </div>
          <p class="salesforce-guided-sync__help">{{i18n
              "salesforce.guided_sync.policy_help"
            }}</p>
          {{#if this.error}}
            <form.Alert
              @type="error"
              @icon="triangle-exclamation"
            >{{this.error}}</form.Alert>
          {{/if}}
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
                @title={{i18n
                  "salesforce.guided_sync.backfill"
                  count=this.group.count
                }}
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
          <form.Field
            @name="previewUser"
            @onSet={{this.setSample}}
            @title={{i18n "salesforce.guided_sync.sample_user"}}
            @type="select"
            as |field|
          >
            <field.Control @includeNone={{false}} as |select|>
              {{#each this.users as |user|}}
                <select.Option @value={{user.id}}>{{user.label}}</select.Option>
              {{/each}}
            </field.Control>
          </form.Field>
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

        {{#if (and (eq this.step 4) this.generatedWorkflows.length)}}
          <AdminConfigAreaCard
            class="salesforce-guided-sync__advanced"
            data-test-advanced-workflows
            @collapsable={{true}}
            @collapsed={{true}}
            @heading="salesforce.guided_sync.generated_workflows"
          >
            <:content>
              <p>{{i18n "salesforce.guided_sync.generated_description"}}</p>
              <div class="salesforce-guided-sync__workflow-list">
                {{#each this.generatedWorkflows key="id" as |workflow|}}
                  <div
                    class="salesforce-guided-sync__workflow-summary"
                    data-test-generated-workflow={{workflow.id}}
                  >
                    <div><h4>{{workflow.name}}</h4><p>{{i18n
                          "salesforce.guided_sync.published"
                        }}</p></div>
                    <div
                      class="salesforce-guided-sync__workflow-actions"
                    ><DButton
                        class="btn-default"
                        @href={{workflow.url}}
                        @label="salesforce.guided_sync.open_workflow"
                      />
                      <DButton
                        class="btn-flat"
                        data-test-workflow-executions={{workflow.id}}
                        @href={{workflow.executionUrl}}
                        @label="salesforce.guided_sync.view_executions"
                      />
                    </div>
                  </div>
                {{/each}}
              </div>
            </:content>
          </AdminConfigAreaCard>
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
