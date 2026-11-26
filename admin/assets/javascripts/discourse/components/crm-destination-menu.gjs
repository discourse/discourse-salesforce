import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { hash } from "@ember/helper";
import { action } from "@ember/object";
import DFilterInput from "discourse/ui-kit/d-filter-input";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import dAutoFocus from "discourse/ui-kit/modifiers/d-auto-focus";
import { i18n } from "discourse-i18n";

const PREFIX = "salesforce.guided_sync.pull";

export default class CrmDestinationMenu extends Component {
  @tracked filter = "";

  get noDestinationLabel() {
    return i18n(`${PREFIX}.no_destination`);
  }

  get filterLabel() {
    return i18n(`${PREFIX}.filter_destinations`);
  }

  get selection() {
    if (!this.args.value) {
      return this.noDestinationLabel;
    }
    return (
      this.args.destinations.find(
        (destination) => destination.id === this.args.value
      )?.name || this.args.value
    );
  }

  get groups() {
    const query = this.filter.trim().toLowerCase();
    return ["details", "custom"]
      .map((id) => ({
        id,
        label: i18n(`${PREFIX}.destination_groups.${id}`),
        destinations: this.args.destinations
          .filter(
            (destination) =>
              destination.group === id &&
              destination.name.toLowerCase().includes(query)
          )
          .map((destination) => ({
            ...destination,
            selected: destination.id === this.args.value,
          })),
      }))
      .filter((group) => group.destinations.length);
  }

  @action
  filterDestinations(event) {
    this.filter = event.target.value;
  }

  @action
  clearFilter() {
    this.filter = "";
  }

  <template>
    <div class="salesforce-source-menu" ...attributes>
      <@control
        @preservePlacement={{true}}
        @selection={{this.selection}}
        as |menu|
      >
        <menu.Container>
          <DFilterInput
            aria-label={{this.filterLabel}}
            placeholder={{this.filterLabel}}
            @containerClass="salesforce-source-menu__search"
            @icons={{hash left="magnifying-glass"}}
            @value={{this.filter}}
            @filterAction={{this.filterDestinations}}
            @onClearInput={{this.clearFilter}}
            {{dAutoFocus}}
          />
        </menu.Container>
        <menu.Item
          class={{dConcatClass
            "salesforce-source-menu__option"
            (unless @value "--selected")
          }}
          data-test-no-destination
          @value=""
        >{{this.noDestinationLabel}}</menu.Item>
        {{#each this.groups as |group|}}
          <menu.Container>
            <p class="salesforce-source-menu__group">{{group.label}}</p>
          </menu.Container>
          {{#each group.destinations key="id" as |destination|}}
            <menu.Item
              class={{dConcatClass
                "salesforce-source-menu__option"
                (if destination.selected "--selected")
              }}
              aria-current={{if destination.selected "true"}}
              @value={{destination.id}}
            >{{destination.name}}</menu.Item>
          {{/each}}
        {{/each}}
      </@control>
    </div>
  </template>
}
