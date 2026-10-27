import { click, fillIn, findAll } from "@ember/test-helpers";

export default async function selectSyncGroups(...names) {
  for (const selected of findAll(
    '[data-name="groups"] .d-multi-select-trigger__selected-item'
  )) {
    await click(selected);
  }
  await click('[data-name="groups"] .d-multi-select-trigger__expand-btn');
  for (const name of names) {
    await fillIn(".d-multi-select__search-input", name);
    await click(".d-multi-select__result");
  }
  await click(".salesforce-guided-sync__heading");
}
