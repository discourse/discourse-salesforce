import { ajax } from "discourse/lib/ajax";
import GuidedSyncRoute from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-route";

export default class SalesforceConfigurationsRoute extends GuidedSyncRoute {
  queryParams = { configuration: { refreshModel: true } };

  async model(params) {
    const result = await ajax(
      "/salesforce/admin/guided-sync/configurations.json"
    );
    return { ...result, selectedId: params.configuration };
  }
}
