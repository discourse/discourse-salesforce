import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import DButton from "discourse/ui-kit/d-button";
import DMultiSelect from "discourse/ui-kit/d-multi-select";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import CrmSegmentBadge from "discourse/plugins/discourse-salesforce/discourse/components/crm-segment-badge";
import SyncConfigurationHeading from "discourse/plugins/discourse-salesforce/discourse/components/sync-configuration-heading";
import {
  badgeLabel,
  createSegment,
  evaluate,
  OPERATORS,
  PROPERTIES,
  syncableGroups,
  tooltipPreview,
  unknownProperties,
} from "discourse/plugins/discourse-salesforce/discourse/lib/crm-segments";

const PREFIX = "salesforce.guided_sync.segments";

export default class CrmSegmentEditor extends Component {
  @service a11y;
  @service dialog;

  @tracked saving = false;
  @tracked segment = structuredClone(this.args.record || createSegment());
  formData = this.segment;

  #form;
  #nextConditionId =
    Math.max(0, ...this.segment.conditions.map((item) => Number(item.id))) + 1;

  get title() {
    return this.segment.name || i18n(`${PREFIX}.default_name`);
  }

  get groups() {
    return syncableGroups(this.args.groups).map((group) => ({
      ...group,
      label: Number.isInteger(group.user_count)
        ? i18n("salesforce.guided_sync.group_option", {
            name: group.name,
            count: group.user_count,
          })
        : group.name,
    }));
  }

  get badgePreview() {
    return badgeLabel(this.segment) || i18n(`${PREFIX}.default_name`);
  }

  get badgeProperties() {
    return (this.segment.badge_properties || []).map(
      (propertyId) =>
        this.properties.find((item) => item.id === propertyId) || {
          id: propertyId,
          label: propertyId,
        }
    );
  }

  get tooltipPreview() {
    return tooltipPreview(this.segment);
  }

  get matchLabel() {
    return i18n(`${PREFIX}.match_${this.segment.match}`);
  }

  get missingProperty() {
    return unknownProperties(this.segment)[0];
  }

  get operators() {
    return OPERATORS.map((operator) => ({
      ...operator,
      label: i18n(`${PREFIX}.operators.${operator.id}`),
    }));
  }

  get preview() {
    const result = evaluate(this.segment);
    return {
      summary: i18n(`${PREFIX}.preview`, {
        count: result.count,
        total: result.total,
      }),
      usernames: result.usernames.slice(0, 8).join(", "),
      more: Math.max(0, result.count - 8),
    };
  }

  get properties() {
    return PROPERTIES.map((property) => ({
      ...property,
      label: i18n(`${PREFIX}.property_option`, {
        object: i18n(`${PREFIX}.objects.${property.object}`),
        label: property.label,
      }),
    }));
  }

  get selectedGroupLabel() {
    const group = this.groups.find(
      (item) => String(item.id) === String(this.segment.group_id)
    );
    return group?.label || i18n(`${PREFIX}.choose_group`);
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
  compareProperties(a, b) {
    return a.id === b.id;
  }

  @action
  async findProperties(query) {
    const term = (query || "").toLowerCase();
    return this.properties.filter(
      (item) =>
        item.label.toLowerCase().includes(term) ||
        item.name.toLowerCase().includes(term)
    );
  }

  @action
  selectBadgeProperties(selection) {
    const ids = selection.map((item) => item.id);
    this.#form?.set("badge_properties", ids);
    this.segment = { ...this.segment, badge_properties: ids };
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
  needsValue(operatorId) {
    return OPERATORS.find((item) => item.id === operatorId)?.valued ?? true;
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
        ? propertyId.split(".")[1]
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
  setField(value, { name, set }) {
    set(name, value);
    this.segment = { ...this.segment, [name]: value };
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
          {{#if this.missingProperty}}
            <form.Alert @type="warning">{{i18n
                "salesforce.guided_sync.segments.errors.property_not_pulled"
                property=this.missingProperty
              }}</form.Alert>
          {{/if}}
          <form.Field
            @name="match"
            @onSet={{this.setField}}
            @title={{i18n "salesforce.guided_sync.segments.match"}}
            @type="menu"
            @validation="required"
            as |field|
          >
            <field.Control @selection={{this.matchLabel}} as |menu|>
              <menu.Item @value="all">{{i18n
                  "salesforce.guided_sync.segments.match_all"
                }}</menu.Item>
              <menu.Item @value="any">{{i18n
                  "salesforce.guided_sync.segments.match_any"
                }}</menu.Item>
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
            <strong>{{this.preview.summary}}</strong>
            {{#if this.preview.usernames}}
              <span class="crm-segment-editor__preview-users">
                {{this.preview.usernames}}
                {{#if this.preview.more}}
                  {{i18n
                    "salesforce.guided_sync.segments.preview_more"
                    count=this.preview.more
                  }}
                {{/if}}
              </span>
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
                @helpText={{i18n "salesforce.guided_sync.segments.group_help"}}
                @name="group_id"
                @onSet={{this.setField}}
                @title={{i18n "salesforce.guided_sync.segments.group"}}
                @type="menu"
                as |field|
              >
                <field.Control @selection={{this.selectedGroupLabel}} as |menu|>
                  {{#each this.groups key="id" as |group|}}
                    <menu.Item @value={{group.id}}>{{group.label}}</menu.Item>
                  {{/each}}
                </field.Control>
              </form.Field>
            {{else}}
              <p class="crm-segment-editor__description">
                {{dIcon "circle-info"}}
                {{i18n "salesforce.guided_sync.segments.no_group_help"}}
              </p>
            {{/if}}
          </div>
        </section>

        <section
          class="crm-segment-editor__section"
          aria-labelledby="crm-segment-badge-title"
        >
          <h3 id="crm-segment-badge-title">{{i18n
              "salesforce.guided_sync.segments.badge_title"
            }}</h3>
          <p class="crm-segment-editor__description">{{i18n
              "salesforce.guided_sync.segments.badge_description"
            }}</p>
          <div class="crm-segment-editor__group-fields">
            <form.Field
              @format="full"
              @name="show_badge"
              @onSet={{this.setField}}
              @title={{i18n "salesforce.guided_sync.segments.show_badge"}}
              @type="checkbox"
              as |field|
            >
              <field.Control />
            </form.Field>
            {{#if this.segment.show_badge}}
              <form.Field
                @format="large"
                @helpText={{i18n
                  "salesforce.guided_sync.segments.badge_label_help"
                }}
                @name="badge_label"
                @onSet={{this.setField}}
                @title={{i18n "salesforce.guided_sync.segments.badge_label"}}
                @type="input"
                as |field|
              >
                <field.Control @maxlength={{40}} placeholder={{this.title}} />
              </form.Field>
              <form.Field
                @format="full"
                @helpText={{i18n
                  "salesforce.guided_sync.segments.badge_properties_help"
                }}
                @name="badge_properties"
                @title={{i18n
                  "salesforce.guided_sync.segments.badge_properties"
                }}
                @type="custom"
                as |field|
              >
                <field.Control>
                  <div class="crm-segment-editor__badge-properties">
                    <DMultiSelect
                      @compareFn={{this.compareProperties}}
                      @label={{i18n
                        "salesforce.guided_sync.segments.choose_badge_properties"
                      }}
                      @loadFn={{this.findProperties}}
                      @matchTriggerWidth={{true}}
                      @onChange={{this.selectBadgeProperties}}
                      @selection={{this.badgeProperties}}
                    >
                      <:selection as |property|>{{property.label}}</:selection>
                      <:result as |property|>
                        <span class="crm-segment-editor__property-label">
                          {{property.label}}
                          <code>{{property.name}}</code>
                        </span>
                      </:result>
                    </DMultiSelect>
                  </div>
                </field.Control>
              </form.Field>
              <div class="crm-segment-editor__badge-preview">
                <span class="crm-segment-editor__description">{{i18n
                    "salesforce.guided_sync.segments.badge_preview"
                  }}</span>
                <CrmSegmentBadge
                  data-test-badge-preview
                  @entries={{this.tooltipPreview}}
                  @label={{this.badgePreview}}
                />
              </div>
              <p class="crm-segment-editor__description">{{i18n
                  "salesforce.guided_sync.segments.badge_visibility_help"
                }}</p>
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
