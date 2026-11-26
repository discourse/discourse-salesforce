import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import GuidedSyncRoute from "discourse/plugins/discourse-salesforce/discourse/lib/guided-sync-route";

export default class SalesforceConfigurationsRoute extends GuidedSyncRoute {
  @service siteSettings;

  queryParams = { configuration: { refreshModel: true } };

  async model(params) {
    const [result, segments] = await Promise.all([
      ajax("/salesforce/admin/guided-sync/configurations.json"),
      this.siteSettings.crm_segments_enabled
        ? ajax("/salesforce/admin/guided-sync/segments.json")
        : null,
    ]);
    return {
      ...result,
      segments: segments?.segments,
      segmentConfigurations: segments?.configurations,
      segmentProperties: segments?.properties,
      segmentGroups: segments?.groups,
      selectedId: params.configuration,
    };
  }
}
