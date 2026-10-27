import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";

export default class SalesforceConfigurationsRoute extends DiscourseRoute {
  @service router;

  beforeModel() {
    return this.router.replaceWith("adminPlugins.show.salesforce-guided-sync", {
      queryParams: { configuration: null },
    });
  }
}
