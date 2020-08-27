import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import I18n from "I18n";

function createPerson(type, context) {
  ajax(`/salesforce/persons/create`, {
    type: "POST",
    data: { type, topic_id: context.topic.id },
  }).catch(popupAjaxError);

  const op = context.topic
    .get("postStream.posts")
    .find((p) => p.post_number === 1);
  context.appEvents.trigger("post-stream:refresh", { id: op.id });
}

function createLead() {
  createPerson("lead", this);
}

function createContact() {
  createPerson("contact", this);
}

function initializeWithApi(api) {
  const currentUser = api.getCurrentUser();
  const isStaff = currentUser && currentUser.staff;

  if (isStaff) {
    const salesforce_url = Discourse.SiteSettings.salesforce_instance_url;

    api.registerTopicFooterButton({
      id: "salesforce-lead",
      icon: "fab-salesforce",
      label: "salesforce.lead.create",
      action: createLead,
    });

    api.registerTopicFooterButton({
      id: "salesforce-contact",
      icon: "fab-salesforce",
      label: "salesforce.contact.create",
      action: createContact,
    });

    api.addPosterIcon((cfs, _) => {
      if (cfs.salesforce_lead_id) {
        return {
          icon: "fab-salesforce",
          className: "salesforce",
          title: I18n.t("salesforce.poster_icon.lead.title"),
          text: I18n.t("salesforce.poster_icon.lead.text"),
          url: `${salesforce_url}/${cfs.salesforce_lead_id}`,
        };
      }
    });

    api.addPosterIcon((cfs, _) => {
      if (cfs.salesforce_contact_id) {
        return {
          icon: "fab-salesforce",
          className: "salesforce",
          title: I18n.t("salesforce.poster_icon.contact.title"),
          text: I18n.t("salesforce.poster_icon.contact.text"),
          url: `${salesforce_url}/${cfs.salesforce_contact_id}`,
        };
      }
    });
  }
}

export default {
  name: "extend-for-salesforce",
  initialize() {
    withPluginApi("0.1", initializeWithApi);
  },
};
