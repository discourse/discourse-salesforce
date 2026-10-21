import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class SalesforceGuidedSyncRoute extends DiscourseRoute {
  queryParams = { configuration: { refreshModel: true } };

  async model(params) {
    const result = await ajax(
      "/salesforce/admin/guided-sync/configurations.json"
    );
    return { ...result, selectedId: params.configuration };
  }
}
