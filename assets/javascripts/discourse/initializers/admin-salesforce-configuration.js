import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "admin-salesforce-configuration",

  initialize(container) {
    if (!container.lookup("service:current-user")?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.setAdminPluginIcon("discourse-salesforce", "fab-salesforce");
      if (
        !container.lookup("service:site-settings")
          .enable_guided_sync_configuration
      ) {
        return;
      }
      api.addAdminPluginConfigurationNav("discourse-salesforce", [
        {
          label: "salesforce.guided_sync.title",
          description: "salesforce.guided_sync.description",
          route: "adminPlugins.show.salesforce-configurations",
          currentWhen: "adminPlugins.show.salesforce-guided-sync",
        },
      ]);
    });
  },
};
