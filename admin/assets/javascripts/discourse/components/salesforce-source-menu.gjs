import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import DFilterInput from "discourse/ui-kit/d-filter-input";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import { i18n } from "discourse-i18n";

export default class SalesforceSourceMenu extends Component {
  @tracked filter = "";

  get selection() {
    return (
      this.args.sources.find((source) => source.id === this.args.value)
        ?.label ||
      this.args.value ||
      i18n("salesforce.guided_sync.choose_source")
    );
  }

  get groups() {
    const query = this.filter.trim().toLowerCase();
    return ["details", "activity", "custom"]
      .map((id) => ({
        id,
        label: i18n(`salesforce.guided_sync.source_groups.${id}`),
        sources: this.args.sources
          .filter(
            (source) =>
              (source.group || "details") === id &&
              source.label.toLowerCase().includes(query)
          )
          .map((source) => ({
            ...source,
            selected: source.id === this.args.value,
          })),
      }))
      .filter((group) => group.sources.length);
  }

  @action
  filterSources(event) {
    this.filter = event.target.value;
  }

  @action
  clearFilter() {
    this.filter = "";
  }

  <template>
    <div class="salesforce-source-menu" ...attributes>
      <@control @selection={{this.selection}} as |menu|>
        <menu.Container>
          <DFilterInput
            aria-label={{i18n "salesforce.guided_sync.filter_sources"}}
            placeholder={{i18n "salesforce.guided_sync.filter_sources"}}
            @containerClass="salesforce-source-menu__search"
            @icons={{hash left="magnifying-glass"}}
            @value={{this.filter}}
            @filterAction={{this.filterSources}}
            @onClearInput={{this.clearFilter}}
          />
        </menu.Container>
        {{#each this.groups as |group|}}
          <menu.Container>
            <p class="salesforce-source-menu__group">{{group.label}}</p>
          </menu.Container>
          {{#each group.sources key="id" as |source|}}
            <menu.Item
              class={{dConcatClass
                "salesforce-source-menu__option"
                (if source.selected "--selected")
              }}
              aria-current={{if source.selected "true"}}
              @value={{source.id}}
            >{{source.label}}</menu.Item>
          {{/each}}
        {{else}}
          <menu.Container><p>{{i18n
                "salesforce.guided_sync.no_sources"
              }}</p></menu.Container>
        {{/each}}
      </@control>
    </div>
  </template>
}
