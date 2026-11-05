import { click, fillIn, find, findAll } from "@ember/test-helpers";

export default async function selectSyncGroups(...names) {
  for (const selected of findAll(
    '[data-name="group_ids"] .d-multi-select-trigger__selected-item'
  )) {
    await click(selected);
  }
  if (!find(".d-multi-select__search-input")) {
    await click('[data-name="group_ids"] .d-multi-select-trigger__expand-btn');
  }
  for (const name of names) {
    await fillIn(".d-multi-select__search-input", name);
    await click(".d-multi-select__result");
  }
  await click(".salesforce-sync-configuration__heading");
}
