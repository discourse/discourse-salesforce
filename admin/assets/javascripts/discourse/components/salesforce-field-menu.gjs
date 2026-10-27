import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import DFilterInput from "discourse/ui-kit/d-filter-input";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import { i18n } from "discourse-i18n";

export default class SalesforceFieldMenu extends Component {
  @tracked filter = "";

  get customSelection() {
    return this.selection.endsWith("__c");
  }

  get selection() {
    return (
      this.args.fields.find((field) => field.id === this.args.value)?.label ||
      this.args.value ||
      i18n("salesforce.guided_sync.choose_field")
    );
  }

  get fields() {
    const query = this.filter.toLowerCase();
    return this.args.fields
      .filter((field) =>
        (field.label || field.id).toLowerCase().includes(query)
      )
      .map((field) => {
        const assigned = this.args.mappings?.find(
          (mapping) =>
            mapping.id !== this.args.mappingId &&
            mapping.destination === field.id
        );
        const source = this.args.sources?.find(
          (item) => item.id === assigned?.source
        );
        return {
          ...field,
          selected: field.id === this.args.value,
          label: field.label || field.id,
          custom: (field.label || field.id).endsWith("__c"),
          description: assigned
            ? i18n("salesforce.guided_sync.mapped_to", {
                source: source?.label || assigned.source,
              })
            : null,
        };
      });
  }

  @action
  filterFields(event) {
    this.filter = event.target.value;
  }

  @action
  clearFilter() {
    this.filter = "";
  }

  <template>
    <div
      class={{dConcatClass
        "salesforce-field-menu"
        (if this.customSelection "--custom")
        (unless @value "--placeholder")
      }}
      role="group"
      aria-label={{i18n "salesforce.guided_sync.salesforce_field"}}
      ...attributes
    >
      <@control @selection={{this.selection}} as |menu|>
        <menu.Container>
          <DFilterInput
            aria-label={{i18n "salesforce.guided_sync.filter_fields"}}
            placeholder={{i18n "salesforce.guided_sync.filter_fields"}}
            @containerClass="salesforce-field-menu__search"
            @icons={{hash left="magnifying-glass"}}
            @value={{this.filter}}
            @filterAction={{this.filterFields}}
            @onClearInput={{this.clearFilter}}
          />
        </menu.Container>
        {{#each this.fields key="id" as |field|}}
          <menu.Item
            class={{dConcatClass
              "salesforce-field-menu__option --with-description"
              (if field.selected "--selected")
            }}
            aria-current={{if field.selected "true"}}
            @value={{field.id}}
          >
            <span class="salesforce-field-menu__option-label"><code
              >{{field.label}}</code>{{#if field.custom}}<span
                  class="salesforce-field-menu__badge"
                >{{i18n
                    "salesforce.guided_sync.custom_field"
                  }}</span>{{/if}}</span>
            {{#if field.description}}<span
                class="salesforce-field-menu__description"
              >{{field.description}}</span>{{/if}}
          </menu.Item>
        {{else}}
          <menu.Container><p>{{i18n
                "salesforce.guided_sync.no_fields"
              }}</p></menu.Container>
        {{/each}}
      </@control>
      {{#if this.customSelection}}<span
          class="salesforce-field-menu__selected-badge"
          aria-hidden="true"
        >{{i18n "salesforce.guided_sync.custom_field"}}</span>{{/if}}
    </div>
  </template>
}
