import { ajax } from "discourse/lib/ajax";
import GuidedSyncRoute from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-route";

export default class SalesforceActivityRoute extends GuidedSyncRoute {
  model() {
    return ajax("/salesforce/admin/guided-sync/activity.json");
  }
}
