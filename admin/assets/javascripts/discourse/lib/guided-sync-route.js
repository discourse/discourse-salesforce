import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";
import { guidedSyncEnabled } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

export default class GuidedSyncRoute extends DiscourseRoute {
  @service router;
  @service siteSettings;

  beforeModel() {
    if (!guidedSyncEnabled(this.siteSettings)) {
      return this.router.replaceWith("adminPlugins.show.settings");
    }
  }
}
