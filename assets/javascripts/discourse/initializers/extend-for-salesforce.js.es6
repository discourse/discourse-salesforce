import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import I18n from "I18n";

function createLead() {
  ajax("/salesforce/leads/create", {
    type: "POST",
    data: { topic_id: this.topic.id },
  }).catch(popupAjaxError);

  const op = this.topic
    .get("postStream.posts")
    .find((p) => p.post_number === 1);
  this.appEvents.trigger("post-stream:refresh", { id: op.id });
}

function initializeWithApi(api) {
  const currentUser = api.getCurrentUser();
  const isStaff = currentUser && currentUser.staff;

  if (isStaff) {
    const salesforce_url = Discourse.SiteSettings.salesforce_instance_url;

    api.registerTopicFooterButton({
      id: "salesforce",
      icon: "fab-salesforce",
      label: "salesforce.lead.create",
      action: createLead,
    });

    api.addPosterIcon((cfs, _) => {
      if (cfs.salesforce_lead_id) {
        return {
          icon: "fab-salesforce",
          className: "salesforce",
          title: I18n.t("salesforce.lead.poster_icon.title"),
          text: I18n.t("salesforce.lead.poster_icon.text"),
          url: `${salesforce_url}/${cfs.salesforce_lead_id}`,
        };
      }
    });
  }
}

export default {
  name: "extend-for-salesforce",
  initialize(container) {
    const siteSettings = container.lookup("site-settings:main");
    withPluginApi("0.1", initializeWithApi);
  },
};
