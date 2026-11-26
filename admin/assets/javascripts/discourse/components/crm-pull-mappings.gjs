import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import CrmDestinationMenu from "discourse/plugins/discourse-salesforce/discourse/components/crm-destination-menu";
import CrmFieldMenu from "discourse/plugins/discourse-salesforce/discourse/components/crm-field-menu";
import { updateMapping } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const PREFIX = "salesforce.guided_sync.pull";

// Rows that copy CRM fields into Discourse fields. `@fields` carry the generic source type
// (text, number, date or boolean) so any CRM can use these rows. With `@storeOnly`, rows only
// pick the CRM fields kept in stored records, for objects that are not matched to users.
export default class CrmPullMappings extends Component {
  destinationsFor = (source) => {
    const field = this.#field(source);
    return this.args.destinations.filter(
      (destination) => !field || destination.accepts.includes(field.type)
    );
  };

  describeField = (id, rowId) =>
    this.args.rows.some((row) => row.id !== rowId && row.source === id)
      ? i18n(`${PREFIX}.field_in_use`)
      : null;

  get matchingHelp() {
    return i18n(`${PREFIX}.matching_help`, {
      provider: this.args.providerName,
    });
  }

  get overwriteLabel() {
    return i18n(`${PREFIX}.policies.overwrite`, {
      provider: this.args.providerName,
    });
  }

  get keepLabel() {
    return i18n(`${PREFIX}.policies.keep`);
  }

  @action
  addRow() {
    const id = Math.max(0, ...this.args.rows.map((row) => row.id)) + 1;
    this.args.onChange([
      ...this.args.rows,
      { id, source: "", destination: "", policy: "overwrite" },
    ]);
  }

  @action
  removeRow(index) {
    this.args.onChange(
      this.args.rows.filter((row, rowIndex) => rowIndex !== index)
    );
  }

  @action
  setRow(property, value, { index }) {
    const rows = updateMapping(
      { mappings: this.args.rows },
      index,
      property,
      value,
      ["source", "destination"]
    );
    const row = rows[index];
    if (
      property === "source" &&
      row.destination &&
      !this.destinationsFor(value).some(({ id }) => id === row.destination)
    ) {
      rows[index] = { ...row, destination: "" };
    }
    this.args.onChange(rows);
  }

  @action
  validateSource(name, value, { addError }) {
    if (
      value &&
      !this.args.loading &&
      !this.args.error &&
      !this.#field(value)
    ) {
      addError(name, {
        title: i18n("salesforce.guided_sync.salesforce_field"),
        message: i18n("salesforce.guided_sync.errors.unavailable", {
          fields: value,
        }),
      });
    }
  }

  #field(id) {
    return this.args.fields.find((field) => field.id === id);
  }

  <template>
    <DConditionalLoadingSpinner
      data-test-pull-fields-loading
      aria-busy={{@loading}}
      @condition={{@loading}}
    >
      {{#if @error}}
        <@form.Alert @type="error">{{@error}}</@form.Alert>
        <DButton
          class="btn-default"
          data-test-refresh-pull-fields
          @action={{fn @onRefresh true}}
          @icon="arrows-rotate"
          @label="salesforce.guided_sync.retry_fields"
        />
      {{else}}
        <div class="salesforce-sync-configuration__mapping-headings">
          <span>{{i18n "salesforce.guided_sync.salesforce_field"}}</span>
          {{#unless @storeOnly}}
            <span></span>
            <span>{{i18n "salesforce.guided_sync.discourse_field"}}</span>
            <span>{{i18n "salesforce.guided_sync.pull.existing_value"}}</span>
          {{/unless}}
        </div>
        {{#unless @storeOnly}}
          <div class="salesforce-sync-configuration__locked-mapping">
            <span>{{dIcon "lock"}} <code>{{@emailField}}</code></span>
            <span class="salesforce-sync-configuration__mapping-arrow">{{dIcon
                "arrow-right"
              }}</span>
            <span>{{i18n "salesforce.guided_sync.email"}}</span>
            <span>{{i18n "salesforce.guided_sync.fixed_mapping"}}</span>
            <p
              class="salesforce-sync-configuration__email-help"
            >{{this.matchingHelp}}</p>
          </div>
        {{/unless}}
        <div
          class="salesforce-sync-configuration__mapping-list"
          id="control-{{@name}}"
        >
          <@form.Collection @name={{@name}} as |collection index row|>
            <div
              class="salesforce-sync-configuration__mapping-row"
              data-test-mapping={{row.source}}
            >
              <collection.Field
                @description={{if
                  (eq row.moved "source")
                  (i18n "salesforce.guided_sync.pull.field_moved")
                }}
                @format="full"
                @name="source"
                @onSet={{fn this.setRow "source"}}
                @title={{i18n "salesforce.guided_sync.salesforce_field"}}
                @type="menu"
                @validate={{this.validateSource}}
                @validation="required"
                as |field|
              >
                <CrmFieldMenu
                  @control={{field.Control}}
                  @describe={{this.describeField}}
                  @fields={{@fields}}
                  @mappingId={{row.id}}
                  @value={{row.source}}
                />
              </collection.Field>
              {{#unless @storeOnly}}
                <span
                  class="salesforce-sync-configuration__mapping-arrow"
                >{{dIcon "arrow-right"}}</span>
                <collection.Field
                  @description={{if
                    (eq row.moved "destination")
                    (i18n "salesforce.guided_sync.pull.destination_moved")
                  }}
                  @format="full"
                  @name="destination"
                  @onSet={{fn this.setRow "destination"}}
                  @title={{i18n "salesforce.guided_sync.discourse_field"}}
                  @type="menu"
                  as |field|
                >
                  <CrmDestinationMenu
                    @control={{field.Control}}
                    @destinations={{this.destinationsFor row.source}}
                    @value={{row.destination}}
                  />
                </collection.Field>
                {{#if row.destination}}
                  <collection.Field
                    @format="full"
                    @name="policy"
                    @onSet={{fn this.setRow "policy"}}
                    @title={{i18n "salesforce.guided_sync.pull.existing_value"}}
                    @type="menu"
                    as |field|
                  >
                    <field.Control
                      @selection={{if
                        (eq row.policy "keep")
                        this.keepLabel
                        this.overwriteLabel
                      }}
                      as |menu|
                    >
                      <menu.Item
                        @value="overwrite"
                      >{{this.overwriteLabel}}</menu.Item>
                      <menu.Item @value="keep">{{this.keepLabel}}</menu.Item>
                    </field.Control>
                  </collection.Field>
                {{/if}}
              {{/unless}}
              <DButton
                class="btn-transparent salesforce-sync-configuration__remove"
                data-test-remove-mapping={{row.id}}
                @action={{fn this.removeRow index}}
                @icon="trash-can"
                @title="salesforce.guided_sync.remove_mapping"
              />
            </div>
          </@form.Collection>
        </div>
        <div class="salesforce-sync-configuration__actions --spread">
          <DButton
            class="btn-flat"
            data-test-add-pull-field
            @action={{this.addRow}}
            @icon="plus"
            @label="salesforce.guided_sync.add_mapping"
          />
          <DButton
            class="btn-flat"
            data-test-refresh-pull-fields
            @action={{fn @onRefresh true}}
            @disabled={{@loading}}
            @icon="arrows-rotate"
            @label="salesforce.guided_sync.refresh_fields"
          />
        </div>
      {{/if}}
    </DConditionalLoadingSpinner>
  </template>
}
