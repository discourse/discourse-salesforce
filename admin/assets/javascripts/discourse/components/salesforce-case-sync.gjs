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
  DEMO_CASE_FIELDS,
  DEMO_SUPPORT_CATEGORIES,
} from "discourse/plugins/discourse-salesforce/discourse/lib/guided-case-sync-demo";

const PREFIX = "salesforce.guided_sync.cases";

export default class SalesforceCaseSync extends Component {
  @service a11y;

  @tracked configuration = structuredClone(this.args.record);
  @tracked connected = Boolean(this.args.connection);
  @tracked saving = false;
  @tracked step = this.args.connection ? 1 : 0;

  formData = this.configuration;

  #form;

  get steps() {
    return ["connect", "scope", "mapping", "responses", "review"]
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

  get canGoBack() {
    return this.step > (this.args.connection ? 1 : 0);
  }

  get currentStepNumber() {
    return this.step + (this.args.connection ? 0 : 1);
  }

  get categories() {
    return DEMO_SUPPORT_CATEGORIES.map((category) => ({
      ...category,
      label: i18n(`${PREFIX}.categories.${category.labelKey}`),
    }));
  }

  get sources() {
    return ["title", "description", "tags", "version", "attachments"].map(
      (id) => ({ id, label: i18n(`${PREFIX}.sources.${id}`) })
    );
  }

  get fileFields() {
    return [{ id: "files", label: i18n(`${PREFIX}.files`) }];
  }

  get fields() {
    return DEMO_CASE_FIELDS.filter((field) => field.type !== "files");
  }

  get mappingError() {
    const mappings = this.configuration.mappings;
    const destinations = mappings
      .map((mapping) => mapping.destination)
      .filter(Boolean);
    const subject = mappings.find(
      (mapping) => mapping.source === "title"
    )?.destination;
    const description = mappings.find(
      (mapping) => mapping.source === "description"
    )?.destination;
    return (
      subject !== "Subject" ||
      description !== "Description" ||
      new Set(destinations).size !== destinations.length ||
      mappings.some((mapping) => !mapping.source || !mapping.destination) ||
      new Set(mappings.map((mapping) => mapping.source)).size !==
        mappings.length
    );
  }

  get continueDisabled() {
    return (
      this.saving || !this.connected || (this.step >= 2 && this.mappingError)
    );
  }

  get preview() {
    return this.configuration.mappings
      .filter((mapping) => mapping.destination)
      .map((mapping) => ({
        ...mapping,
        label: i18n(`${PREFIX}.sources.${mapping.source}`),
        destinationLabel:
          mapping.destination === "files"
            ? i18n(`${PREFIX}.files`)
            : mapping.destination,
        value: i18n(`${PREFIX}.example.${mapping.source}`),
      }));
  }

  get workflows() {
    return (this.args.record.workflows || []).map((workflow) => ({
      ...workflow,
      url: `/admin/plugins/discourse-workflows/workflows/${workflow.id}`,
      executionUrl: `/admin/plugins/discourse-workflows/workflows/${workflow.id}/executions`,
    }));
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
    this.a11y.announce(i18n("salesforce.guided_sync.connected_message"));
  }

  @action
  navigate(index) {
    this.step = index;
  }

  @action
  previous() {
    this.step--;
  }

  @action
  registerForm(form) {
    this.#form = form;
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
    const mappings = this.configuration.mappings.map((mapping, position) =>
      position === index
        ? { ...mapping, [property]: value, moved: false }
        : property === "destination" && value && mapping.destination === value
          ? { ...mapping, destination: "", moved: true }
          : mapping
    );
    this.#form.set("mappings", mappings);
    this.configuration = { ...this.configuration, mappings };
  }

  @action
  addMapping() {
    const mappings = [
      ...this.configuration.mappings,
      {
        id:
          Math.max(
            0,
            ...this.configuration.mappings.map((mapping) => Number(mapping.id))
          ) + 1,
        source: "",
        destination: "",
        policy: "overwrite",
      },
    ];
    this.#form.set("mappings", mappings);
    this.configuration = { ...this.configuration, mappings };
  }

  @action
  removeMapping(index) {
    const mappings = this.configuration.mappings.filter(
      (mapping, position) => position !== index
    );
    this.#form.set("mappings", mappings);
    this.configuration = { ...this.configuration, mappings };
  }

  @action
  async advance() {
    if (this.continueDisabled) {
      return;
    }
    if (this.step < 4) {
      this.step++;
      return;
    }
    this.saving = true;
    try {
      const saved = await this.args.onSave(this.configuration);
      if (saved) {
        this.a11y.announce(i18n("salesforce.guided_sync.workflows_saved"));
      }
    } finally {
      this.saving = false;
    }
  }

  <template>
    <div
      class="salesforce-guided-sync salesforce-case-sync admin-config-page__main-area"
      ...attributes
    >
      <DPageSubheader
        @titleLabel={{this.configuration.name}}
        @descriptionLabel={{i18n "salesforce.guided_sync.cases.description"}}
      />

      <nav
        class="salesforce-guided-sync__steps"
        aria-label={{i18n "salesforce.guided_sync.steps_label"}}
      >
        {{#each this.steps as |step|}}
          <DButton
            class={{dConcatClass
              "btn-flat salesforce-guided-sync__step"
              (if step.current "--current")
              (if step.completed "--completed")
            }}
            aria-current={{if step.current "step"}}
            data-test-case-step={{step.id}}
            @action={{fn this.navigate step.index}}
            @disabled={{step.disabled}}
            @translatedLabel={{step.label}}
          />
        {{/each}}
      </nav>
      <Form
        class="salesforce-guided-sync__form"
        @data={{this.formData}}
        @onRegisterApi={{this.registerForm}}
        @onSubmit={{this.advance}}
        as |form|
      >
        {{#if (eq this.step 0)}}
          <AdminConfigAreaCard
            class="salesforce-guided-sync__form-card"
            @heading="salesforce.guided_sync.connect_title"
            @description="salesforce.guided_sync.connect_description"
          >
            <:content>
              <SalesforceConnectionSummary @connected={{this.connected}} />
              <form.Field
                @name="environment"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.environment"}}
                @type="select"
                as |field|
              >
                <field.Control @includeNone={{false}} as |select|>
                  <select.Option @value="sandbox">{{i18n
                      "salesforce.guided_sync.sandbox"
                    }}</select.Option>
                  <select.Option @value="production">{{i18n
                      "salesforce.guided_sync.production"
                    }}</select.Option>
                </field.Control>
              </form.Field>
              {{#unless this.connected}}
                <DButton
                  class="btn-primary"
                  data-test-case-connect
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
            @heading="salesforce.guided_sync.cases.scope_title"
            @description="salesforce.guided_sync.cases.scope_description"
          >
            <:content>
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
              <form.Field
                @name="category"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.cases.category"}}
                @type="select"
                @validation="required"
                as |field|
              >
                <field.Control @includeNone={{false}} as |select|>
                  {{#each this.categories as |category|}}
                    <select.Option
                      @value={{category.id}}
                    >{{category.label}}</select.Option>
                  {{/each}}
                </field.Control>
              </form.Field>
              <p>{{i18n "salesforce.guided_sync.cases.one_case"}}</p>
              <form.Field
                @name="backfill"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.cases.backfill"}}
                @type="checkbox"
                as |field|
              ><field.Control /></form.Field>
            </:content>
          </AdminConfigAreaCard>
        {{else if (eq this.step 2)}}
          <h3>{{i18n "salesforce.guided_sync.cases.mapping_title"}}</h3>
          <p>{{i18n "salesforce.guided_sync.cases.mapping_description"}}</p>
          {{#if this.mappingError}}<p class="alert alert-error">{{i18n
                "salesforce.guided_sync.cases.mapping_error"
              }}</p>{{/if}}
          <div
            class="salesforce-guided-sync__mapping-headings"
            aria-hidden="true"
          >
            <span>{{i18n "salesforce.guided_sync.discourse_field"}}</span><span
            ></span><span>{{i18n
                "salesforce.guided_sync.salesforce_field"
              }}</span><span>{{i18n
                "salesforce.guided_sync.existing_value"
              }}</span>
          </div>
          <div class="salesforce-guided-sync__mapping-list">
            <form.Collection @name="mappings" as |collection index mapping|>
              <div
                class="salesforce-guided-sync__mapping-row"
                data-test-case-mapping={{mapping.source}}
              >
                <collection.Field
                  @format="full"
                  @name="source"
                  @onSet={{fn this.setMapping "source"}}
                  @showTitle={{false}}
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
                    {{#each this.sources as |source|}}<select.Option
                        @value={{source.id}}
                      >{{source.label}}</select.Option>{{/each}}
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
                    @fields={{if
                      (eq mapping.source "attachments")
                      this.fileFields
                      this.fields
                    }}
                    @mappings={{this.configuration.mappings}}
                    @mappingId={{mapping.id}}
                    @sources={{this.sources}}
                  />
                </collection.Field>
                <collection.Field
                  @disabled={{eq mapping.source "attachments"}}
                  @format="full"
                  @name="policy"
                  @onSet={{fn this.setMapping "policy"}}
                  @showTitle={{false}}
                  @title={{i18n "salesforce.guided_sync.existing_value"}}
                  @type="select"
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
              @action={{this.addMapping}}
              @icon="plus"
              @label="salesforce.guided_sync.add_mapping"
            />
            <span class="salesforce-guided-sync__help">{{i18n
                "salesforce.guided_sync.cases.field_list_note"
              }}</span>
          </div>
          <p class="alert alert-info">{{i18n
              "salesforce.guided_sync.cases.form_help"
            }}</p>
          <p>{{i18n "salesforce.guided_sync.cases.attachments_help"}}</p>
        {{else if (eq this.step 3)}}
          <AdminConfigAreaCard
            class="salesforce-guided-sync__form-card"
            @heading="salesforce.guided_sync.cases.responses_title"
            @description="salesforce.guided_sync.cases.responses_description"
          >
            <:content>
              <form.Field
                @name="onEdit"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.cases.on_edit"}}
                @type="checkbox"
                as |field|
              ><field.Control /></form.Field>
              <form.Field
                @name="outboundReplies"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.cases.outbound"}}
                @type="checkbox"
                as |field|
              ><field.Control /></form.Field>
              <form.Field
                @name="inboundReplies"
                @onSet={{this.setConfiguration}}
                @title={{i18n "salesforce.guided_sync.cases.inbound"}}
                @type="checkbox"
                as |field|
              ><field.Control /></form.Field>
              <p class="alert alert-info">{{i18n
                  "salesforce.guided_sync.cases.public_only"
                }}</p>
              <p>{{i18n "salesforce.guided_sync.cases.loop_help"}}</p>
            </:content>
          </AdminConfigAreaCard>
        {{else}}
          <h3>{{i18n "salesforce.guided_sync.cases.review_title"}}</h3>
          <p>{{i18n
              "salesforce.guided_sync.cases.review_scope"
              category=this.configuration.category
            }}</p>
          <table class="d-table salesforce-guided-sync__preview">
            <thead class="d-table__header"><tr><th>{{i18n
                    "salesforce.guided_sync.discourse_field"
                  }}</th><th>{{i18n
                    "salesforce.guided_sync.salesforce_field"
                  }}</th><th>{{i18n
                    "salesforce.guided_sync.cases.sample_value"
                  }}</th></tr></thead>
            <tbody class="d-table__body">{{#each
                this.preview key="source"
                as |row|
              }}<tr
                  class="d-table__row"
                  data-test-case-preview={{row.source}}
                ><td class="d-table__cell --overview">{{row.label}}</td><td
                    class="d-table__cell --detail"
                  ><div class="d-table__mobile-label">{{i18n
                        "salesforce.guided_sync.salesforce_field"
                      }}</div>{{row.destinationLabel}}</td><td
                  >{{row.value}}</td></tr>{{/each}}</tbody>
          </table>
          <AdminConfigAreaCard
            class="salesforce-guided-sync__form-card"
            @heading="salesforce.guided_sync.cases.response_preview"
          >
            <:content>
              <p>{{i18n "salesforce.guided_sync.cases.outbound"}}:
                <strong>{{i18n
                    (if
                      this.configuration.outboundReplies
                      "salesforce.guided_sync.cases.included"
                      "salesforce.guided_sync.cases.excluded"
                    )
                  }}</strong></p>
              {{#if this.configuration.outboundReplies}}<blockquote>{{i18n
                    "salesforce.guided_sync.cases.example.customer_reply"
                  }}</blockquote>{{/if}}
              <p>{{i18n "salesforce.guided_sync.cases.inbound"}}:
                <strong>{{i18n
                    (if
                      this.configuration.inboundReplies
                      "salesforce.guided_sync.cases.included"
                      "salesforce.guided_sync.cases.excluded"
                    )
                  }}</strong></p>
              {{#if this.configuration.inboundReplies}}<blockquote>{{i18n
                    "salesforce.guided_sync.cases.example.agent_reply"
                  }}</blockquote>{{/if}}
              <p>{{i18n "salesforce.guided_sync.cases.public_only"}}</p>
            </:content>
          </AdminConfigAreaCard>
        {{/if}}
        {{#if (and (eq this.step 4) this.workflows.length)}}
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
                {{#each this.workflows key="id" as |workflow|}}
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

        <div class="salesforce-guided-sync__footer">
          <span>{{i18n
              "salesforce.guided_sync.step_progress"
              current=this.currentStepNumber
              total=this.steps.length
            }}</span>
          <div class="salesforce-guided-sync__actions">
            {{#if @onCancel}}
              <DButton
                class="btn-flat"
                data-test-configurations-back
                @action={{@onCancel}}
                @label="salesforce.guided_sync.cancel_setup"
              />
            {{/if}}
            {{#if this.canGoBack}}<DButton
                class="btn-default"
                @action={{this.previous}}
                @label="salesforce.guided_sync.back"
              />{{/if}}
            <form.Submit
              data-test-case-continue
              @disabled={{this.continueDisabled}}
              @label={{if
                (eq this.step 4)
                "salesforce.guided_sync.enable"
                "salesforce.guided_sync.continue"
              }}
            />
          </div>
        </div>
      </Form>

    </div>
  </template>
}
