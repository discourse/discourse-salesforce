import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { cancel } from "@ember/runloop";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import discourseDebounce from "discourse/lib/debounce";
import { not } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DMultiSelect from "discourse/ui-kit/d-multi-select";
import { i18n } from "discourse-i18n";
import CrmCreateGroupModal from "discourse/plugins/discourse-salesforce/discourse/components/crm-create-group-modal";
import SyncConfigurationHeading from "discourse/plugins/discourse-salesforce/discourse/components/sync-configuration-heading";
import {
  conditionNeedsValue,
  conditionsPayload,
  configurationProperties,
  OPERATORS,
  previewSegment,
  propertyLabel,
} from "discourse/plugins/discourse-salesforce/discourse/lib/crm-segments";

const PREFIX = "salesforce.guided_sync.segments";
const PREVIEW_DELAY = 300;
const PREVIEW_USERNAMES = 8;

export default class CrmSegmentEditor extends Component {
  @service a11y;
  @service dialog;
  @service modal;

  @tracked createdGroups = [];
  @tracked preview;
  @tracked saving = false;
  @tracked segment = structuredClone(this.args.record);
  formData = this.segment;

  #form;
  #nextConditionId =
    Math.max(0, ...this.segment.conditions.map((item) => Number(item.id))) + 1;
  #previewRequest = 0;
  #previewTimer;

  constructor() {
    super(...arguments);
    this.#schedulePreview();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.#previewRequest++;
    cancel(this.#previewTimer);
  }

  get title() {
    return this.segment.name || i18n(`${PREFIX}.default_name`);
  }

  get groups() {
    return [
      ...new Map(
        [...this.args.groups, ...this.createdGroups].map((group) => [
          String(group.id),
          group,
        ])
      ).values(),
    ];
  }

  get selectedGroups() {
    const group = this.groups.find(
      (item) => String(item.id) === String(this.segment.group_id)
    );
    return group ? [group] : [];
  }

  get configurationProperties() {
    return configurationProperties(
      this.args.properties,
      this.segment.configuration_id
    );
  }

  get missingProperty() {
    const properties = this.configurationProperties;
    const missing = this.segment.conditions
      .map((item) => item.property)
      .filter(
        (propertyId) =>
          propertyId && !properties.some((item) => item.id === propertyId)
      );
    return missing[0] && propertyLabel(missing[0], properties);
  }

  get operators() {
    return OPERATORS.map((operator) => ({
      ...operator,
      label: i18n(`${PREFIX}.operators.${operator.id}`),
    }));
  }

  get previewSummary() {
    if (!this.preview) {
      return null;
    }
    return {
      summary: i18n(`${PREFIX}.preview`, {
        count: this.preview.count,
        total: this.preview.total,
      }),
      usernames: this.preview.usernames.join(", "),
      more: Math.max(0, this.preview.count - PREVIEW_USERNAMES),
    };
  }

  get properties() {
    return this.configurationProperties.map((property) => ({
      ...property,
      label: i18n(`${PREFIX}.property_option`, {
        object: i18n(`${PREFIX}.objects.${property.object}`, {
          defaultValue: property.object,
        }),
        label: property.label,
      }),
    }));
  }

  get submitLabel() {
    return this.args.record?.id
      ? "salesforce.guided_sync.save_changes"
      : `${PREFIX}.save`;
  }

  @action
  addCondition() {
    this.#setConditions([
      ...this.segment.conditions,
      {
        id: this.#nextConditionId++,
        property: "",
        operator: "equals",
        value: "",
      },
    ]);
  }

  @action
  allowNavigation() {
    return false;
  }

  @action
  applyName(value) {
    this.#form?.set("name", value);
    this.segment = { ...this.segment, name: value };
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
  compareGroups(a, b) {
    return String(a.id) === String(b.id);
  }

  @action
  async createGroup(menu) {
    await menu.close();
    this.modal.show(CrmCreateGroupModal, {
      model: { onCreated: this.groupCreated },
    });
  }

  @action
  async findGroups(query) {
    const term = (query || "").toLowerCase();
    return this.groups.filter((group) =>
      group.name.toLowerCase().includes(term)
    );
  }

  @action
  groupCreated(group) {
    this.createdGroups = [...this.createdGroups, group];
    this.selectGroups([group]);
    this.a11y.announce(
      i18n("salesforce.guided_sync.group_created", { name: group.name })
    );
  }

  @action
  selectGroups(groups) {
    const group = groups.at(-1);
    const groupId = group ? group.id : null;
    this.#form?.set("group_id", groupId);
    this.segment = { ...this.segment, group_id: groupId };
  }

  @action
  needsValue(operatorId) {
    return conditionNeedsValue(operatorId);
  }

  @action
  operatorLabel(operatorId) {
    return this.operators.find((item) => item.id === operatorId)?.label;
  }

  @action
  propertyLabel(propertyId) {
    return (
      this.properties.find((item) => item.id === propertyId)?.label ||
      (propertyId
        ? propertyLabel(propertyId, this.configurationProperties)
        : i18n(`${PREFIX}.choose_property`))
    );
  }

  @action
  registerForm(form) {
    this.#form = form;
  }

  @action
  removeCondition(index) {
    this.#setConditions(
      this.segment.conditions.filter((item, itemIndex) => itemIndex !== index)
    );
  }

  @action
  async save() {
    if (this.saving || !this.args.onSave) {
      return;
    }
    this.saving = true;
    try {
      if (await this.args.onSave({ ...this.segment, name: this.title })) {
        this.a11y.announce(i18n(`${PREFIX}.saved`));
      }
    } finally {
      this.saving = false;
    }
  }

  @action
  setCondition(property, value, { index }) {
    this.#setConditions(
      this.segment.conditions.map((item, itemIndex) =>
        itemIndex === index ? { ...item, [property]: value } : item
      )
    );
  }

  @action
  setConfiguration(value, { set }) {
    set("configuration_id", value);
    this.segment = { ...this.segment, configuration_id: value };
    this.#setConditions([
      {
        id: this.#nextConditionId++,
        property: "",
        operator: "equals",
        value: "",
      },
    ]);
  }

  @action
  setField(value, { name, set }) {
    set(name, value);
    this.segment = { ...this.segment, [name]: value };
    if (name === "match") {
      this.#schedulePreview();
    }
  }

  @action
  validateSegment(data, { addError, removeError }) {
    removeError("conditions");
    removeError("group_id");
    const complete = data.conditions.filter(
      (item) => item.property && item.operator
    );
    const blank = data.conditions.some(
      (item) => this.needsValue(item.operator) && !item.value?.trim()
    );
    if (complete.length === 0 || blank) {
      addError("conditions", {
        title: i18n(`${PREFIX}.conditions_title`),
        message: i18n(`${PREFIX}.errors.incomplete_conditions`),
      });
    }
    if (data.sync_group && !data.group_id) {
      addError("group_id", {
        title: i18n(`${PREFIX}.group`),
        message: i18n(`${PREFIX}.errors.group_required`),
      });
    }
  }

  #setConditions(conditions) {
    this.#form?.set("conditions", conditions);
    this.segment = { ...this.segment, conditions };
    this.#schedulePreview();
  }

  #schedulePreview() {
    this.#previewRequest++;
    this.#previewTimer = discourseDebounce(
      this,
      this.#loadPreview,
      PREVIEW_DELAY
    );
  }

  async #loadPreview() {
    const conditions = conditionsPayload(this.segment);
    const complete = conditions[this.segment.match].filter(
      (item) => !this.needsValue(item.operator) || item.value.trim()
    );
    if (complete.length === 0 || this.missingProperty) {
      this.preview = null;
      return;
    }
    const request = this.#previewRequest;
    try {
      const result = await previewSegment(this.segment.configuration_id, {
        [this.segment.match]: complete,
      });
      if (request === this.#previewRequest) {
        this.preview = result;
      }
    } catch {
      if (request === this.#previewRequest) {
        this.preview = null;
      }
    }
  }

  <template>
    <div class="crm-segment-editor admin-config-page__main-area" ...attributes>
      <SyncConfigurationHeading
        class="crm-segment-editor__heading"
        @editable={{@onSave}}
        @onApply={{this.applyName}}
        @title={{this.title}}
      />
      <p>{{i18n "salesforce.guided_sync.segments.editor_description"}}</p>

      <Form
        class="crm-segment-editor__form"
        @data={{this.formData}}
        @onDirtyCheck={{this.allowNavigation}}
        @onRegisterApi={{this.registerForm}}
        @onSubmit={{this.save}}
        @validate={{this.validateSegment}}
        @validateOn="submit"
        as |form|
      >
        <section
          class="crm-segment-editor__section"
          aria-labelledby="crm-segment-conditions-title"
        >
          <h3 id="crm-segment-conditions-title">{{i18n
              "salesforce.guided_sync.segments.conditions_title"
            }}</h3>
          <p class="crm-segment-editor__description">{{i18n
              "salesforce.guided_sync.segments.conditions_description"
            }}</p>
          <form.Field
            class="crm-segment-editor__configuration"
            @disabled={{@record.id}}
            @format="large"
            @name="configuration_id"
            @onSet={{this.setConfiguration}}
            @title={{i18n "salesforce.guided_sync.segments.configuration"}}
            @type="select"
            @validation="required"
            as |field|
          >
            <field.Control as |select|>
              {{#each @configurations key="id" as |configuration|}}
                <select.Option
                  @value={{configuration.id}}
                >{{configuration.name}}</select.Option>
              {{/each}}
            </field.Control>
          </form.Field>
          {{#if this.missingProperty}}
            <form.Alert @type="warning">{{i18n
                "salesforce.guided_sync.segments.errors.property_not_pulled"
                property=this.missingProperty
              }}</form.Alert>
          {{/if}}
          <form.Field
            class="crm-segment-editor__match"
            @format="full"
            @name="match"
            @onSet={{this.setField}}
            @title={{i18n "salesforce.guided_sync.segments.match"}}
            @type="radio-group"
            @validation="required"
            as |field|
          >
            <field.Control class="--inline" as |radioGroup|>
              <radioGroup.Radio @value="all">{{i18n
                  "salesforce.guided_sync.segments.match_all"
                }}</radioGroup.Radio>
              <radioGroup.Radio @value="any">{{i18n
                  "salesforce.guided_sync.segments.match_any"
                }}</radioGroup.Radio>
            </field.Control>
          </form.Field>
          <div class="crm-segment-editor__conditions" id="control-conditions">
            <form.Collection @name="conditions" as |collection index item|>
              <div
                class="crm-segment-editor__condition"
                data-test-condition={{item.id}}
              >
                <collection.Field
                  @format="full"
                  @name="property"
                  @onSet={{fn this.setCondition "property"}}
                  @showTitle={{false}}
                  @title={{i18n "salesforce.guided_sync.segments.property"}}
                  @type="menu"
                  @validation="required"
                  as |field|
                >
                  <field.Control
                    @selection={{this.propertyLabel item.property}}
                    as |menu|
                  >
                    {{#each this.properties key="id" as |property|}}
                      <menu.Item @value={{property.id}}>
                        <span class="crm-segment-editor__property-label">
                          {{property.label}}
                          <code>{{property.name}}</code>
                        </span>
                      </menu.Item>
                    {{/each}}
                  </field.Control>
                </collection.Field>
                <collection.Field
                  @format="full"
                  @name="operator"
                  @onSet={{fn this.setCondition "operator"}}
                  @showTitle={{false}}
                  @title={{i18n "salesforce.guided_sync.segments.operator"}}
                  @type="menu"
                  @validation="required"
                  as |field|
                >
                  <field.Control
                    @selection={{this.operatorLabel item.operator}}
                    as |menu|
                  >
                    {{#each this.operators key="id" as |operator|}}
                      <menu.Item
                        @value={{operator.id}}
                      >{{operator.label}}</menu.Item>
                    {{/each}}
                  </field.Control>
                </collection.Field>
                {{#if (this.needsValue item.operator)}}
                  <collection.Field
                    @format="full"
                    @name="value"
                    @onSet={{fn this.setCondition "value"}}
                    @showTitle={{false}}
                    @title={{i18n "salesforce.guided_sync.segments.value"}}
                    @type="input"
                    as |field|
                  >
                    <field.Control
                      aria-label={{i18n
                        "salesforce.guided_sync.segments.value"
                      }}
                      placeholder={{i18n
                        "salesforce.guided_sync.segments.value"
                      }}
                    />
                  </collection.Field>
                {{/if}}
                <DButton
                  class="btn-transparent crm-segment-editor__remove"
                  data-test-remove-condition={{item.id}}
                  @action={{fn this.removeCondition index}}
                  @icon="trash-can"
                  @title="salesforce.guided_sync.segments.remove_condition"
                />
              </div>
            </form.Collection>
          </div>
          <DButton
            class="btn-flat"
            data-test-add-condition
            @action={{this.addCondition}}
            @icon="plus"
            @label="salesforce.guided_sync.segments.add_condition"
          />
          <div class="crm-segment-editor__preview" data-test-preview>
            {{#if this.previewSummary}}
              <strong>{{this.previewSummary.summary}}</strong>
              {{#if this.previewSummary.usernames}}
                <span class="crm-segment-editor__preview-users">
                  {{this.previewSummary.usernames}}
                  {{#if this.previewSummary.more}}
                    {{i18n
                      "salesforce.guided_sync.segments.preview_more"
                      count=this.previewSummary.more
                    }}
                  {{/if}}
                </span>
              {{/if}}
            {{else}}
              <strong>{{i18n
                  "salesforce.guided_sync.segments.preview_empty"
                }}</strong>
            {{/if}}
            <span class="crm-segment-editor__description">{{i18n
                "salesforce.guided_sync.segments.preview_help"
              }}</span>
          </div>
        </section>

        <section
          class="crm-segment-editor__section"
          aria-labelledby="crm-segment-group-title"
        >
          <h3 id="crm-segment-group-title">{{i18n
              "salesforce.guided_sync.segments.group_title"
            }}</h3>
          <p class="crm-segment-editor__description">{{i18n
              "salesforce.guided_sync.segments.group_description"
            }}</p>
          <div class="crm-segment-editor__group-fields">
            <form.Field
              @format="full"
              @name="sync_group"
              @onSet={{this.setField}}
              @title={{i18n "salesforce.guided_sync.segments.sync_group"}}
              @type="checkbox"
              as |field|
            >
              <field.Control />
            </form.Field>
            {{#if this.segment.sync_group}}
              <form.Field
                class="crm-segment-editor__group"
                @format="full"
                @helpText={{i18n "salesforce.guided_sync.segments.group_help"}}
                @name="group_id"
                @showOptional={{false}}
                @title={{i18n "salesforce.guided_sync.segments.group"}}
                @type="custom"
                as |field|
              >
                <field.Control>
                  <div class="crm-segment-editor__group-controls">
                    <DMultiSelect
                      @compareFn={{this.compareGroups}}
                      @label={{i18n
                        "salesforce.guided_sync.segments.choose_group"
                      }}
                      @loadFn={{this.findGroups}}
                      @matchTriggerWidth={{true}}
                      @onChange={{this.selectGroups}}
                      @selection={{this.selectedGroups}}
                    >
                      <:selection as |group|>{{group.name}}</:selection>
                      <:result as |group|>{{group.name}}</:result>
                      <:footer as |menu|>
                        <DButton
                          class="btn-flat crm-segment-editor__create-group"
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
                @disabled={{not this.segment.group_id}}
                @format="full"
                @helpText={{i18n
                  "salesforce.guided_sync.segments.remove_unmatched_help"
                }}
                @name="remove_unmatched"
                @onSet={{this.setField}}
                @title={{i18n
                  "salesforce.guided_sync.segments.remove_unmatched"
                }}
                @type="checkbox"
                as |field|
              >
                <field.Control />
              </form.Field>
            {{/if}}
          </div>
        </section>

        <form.Actions class="crm-segment-editor__footer">
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
