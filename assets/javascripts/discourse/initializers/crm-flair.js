import { withPluginApi } from "discourse/lib/plugin-api";
import CrmPostFlair from "../components/crm-post-flair";

export default {
  name: "crm-flair",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (!siteSettings.crm_segments_enabled) {
      return;
    }

    withPluginApi((api) => {
      api.addTrackedPostProperties("crm_flair");
      api.renderAfterWrapperOutlet("post-meta-data-poster-name", CrmPostFlair);
    });
  },
};
