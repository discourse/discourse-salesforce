import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import DButton from "discourse/ui-kit/d-button";
import DMultiSelect from "discourse/ui-kit/d-multi-select";
import { i18n } from "discourse-i18n";
import CrmCreateGroupModal from "discourse/plugins/discourse-salesforce/discourse/components/crm-create-group-modal";

// Picks the Discourse groups a sync applies to and can create a group on the spot.
// `@groups` is the list known up front, used when searching fails.
export default class CrmGroupSelect extends Component {
  @service a11y;
  @service modal;

  #created = [];

  @action
  async findGroups(query) {
    try {
      const result = await ajax("/salesforce/admin/guided-sync/groups.json", {
        data: { q: query || "" },
      });
      return [
        ...new Map(
          [...result.groups, ...this.#created].map((group) => [
            String(group.id),
            group,
          ])
        ).values(),
      ];
    } catch {
      return [...(this.args.groups || []), ...this.#created].filter((group) =>
        group.name.toLowerCase().includes((query || "").toLowerCase())
      );
    }
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
  groupCreated(group) {
    this.#created = [...this.#created, group];
    this.args.onCreated?.(group);
    if (!this.args.selection.some((item) => this.compareGroups(item, group))) {
      this.args.onChange([...this.args.selection, group]);
    }
    this.a11y.announce(
      i18n("salesforce.guided_sync.group_created", { name: group.name })
    );
  }

  <template>
    <div class="salesforce-sync-configuration__group-controls">
      <DMultiSelect
        @compareFn={{this.compareGroups}}
        @label={{i18n "salesforce.guided_sync.group"}}
        @loadFn={{this.findGroups}}
        @matchTriggerWidth={{true}}
        @onChange={{@onChange}}
        @selection={{@selection}}
      >
        <:selection as |group|>{{group.name}}</:selection>
        <:result as |group|>{{group.name}}</:result>
        <:footer as |menu|>
          <DButton
            class="btn-flat salesforce-sync-configuration__create-group"
            data-test-create-group
            @action={{fn this.createGroup menu}}
            @icon="plus"
            @label="salesforce.guided_sync.create_group"
          />
        </:footer>
      </DMultiSelect>
    </div>
  </template>
}
