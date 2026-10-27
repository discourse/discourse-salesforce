import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class SalesforceGuidedSyncRoute extends DiscourseRoute {
  @service router;
  @service siteSettings;

  queryParams = { configuration: { refreshModel: true } };

  beforeModel() {
    if (!this.siteSettings.enable_guided_sync_configuration) {
      return this.router.replaceWith("adminPlugins.show.settings");
    }
  }

  async model(params) {
    const result = await ajax(
      "/salesforce/admin/guided-sync/configurations.json"
    );
    return { ...result, selectedId: params.configuration };
  }
}
