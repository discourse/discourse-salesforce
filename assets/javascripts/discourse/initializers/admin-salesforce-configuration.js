import { withPluginApi } from "discourse/lib/plugin-api";
import { guidedSyncEnabled } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

export default {
  name: "admin-salesforce-configuration",

  initialize(container) {
    if (!container.lookup("service:current-user")?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.setAdminPluginIcon("discourse-salesforce", "fab-salesforce");
      if (!guidedSyncEnabled(container.lookup("service:site-settings"))) {
        return;
      }
      api.addAdminPluginConfigurationNav("discourse-salesforce", [
        {
          label: "salesforce.guided_sync.title",
          description: "salesforce.guided_sync.description",
          route: "adminPlugins.show.salesforce-configurations",
        },
        {
          label: "admin.plugins.change_settings_short",
          route: "adminPlugins.show.settings",
        },
        {
          label: "salesforce.activity.title",
          description: "salesforce.activity.description",
          route: "adminPlugins.show.salesforce-activity",
        },
      ]);
    });
  },
};
