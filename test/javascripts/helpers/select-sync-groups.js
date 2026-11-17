import { click, fillIn, find } from "@ember/test-helpers";

export default async function selectSyncGroups(...names) {
  const selectedItem =
    '[data-name="group_ids"] .d-multi-select-trigger__selected-item';
  while (find(selectedItem)) {
    await click(selectedItem);
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
