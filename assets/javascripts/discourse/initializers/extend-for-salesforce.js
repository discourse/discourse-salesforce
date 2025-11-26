import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";
import PostSalesforceCase from "../components/post-salesforce-case";

async function createPerson(type, post) {
  post.set("flair_url", "loading spinner");

  try {
    await ajax(`/salesforce/persons/create`, {
      type: "POST",
      data: { type, user_id: post.user_id },
    });
    post.set("flair_url", "fab-salesforce");
  } catch (error) {
    popupAjaxError(error);
  }
}

function initializeWithApi(api, container) {
  const currentUser = api.getCurrentUser();
  const isStaff = currentUser?.staff;

  if (isStaff) {
    const siteSettings = container.lookup("service:site-settings");
    const salesforceUrl = siteSettings.salesforce_instance_url;

    api.addPostAdminMenuButton(() => {
      return {
        icon: "user-plus",
        label: "salesforce.lead.create",
        action: async (post) => {
          await createPerson("lead", post);
        },
        className: "create-lead",
      };
    });

    api.addPostAdminMenuButton(() => {
      return {
        icon: "address-card",
        label: "salesforce.contact.create",
        action: async (post) => {
          await createPerson("contact", post);
        },
        className: "create-contact",
      };
    });

    api.addPosterIcon((cfs) => {
      if (cfs.salesforce_lead_id) {
        return {
          icon: "user-plus",
          className: "salesforce-lead",
          title: i18n("salesforce.poster_icon.lead.title"),
          url: `${salesforceUrl}/${cfs.salesforce_lead_id}`,
        };
      }
    });

    api.addPosterIcon((cfs) => {
      if (cfs.salesforce_contact_id) {
        return {
          icon: "address-card",
          className: "salesforce-contact",
          title: i18n("salesforce.poster_icon.contact.title"),
          url: `${salesforceUrl}/${cfs.salesforce_contact_id}`,
        };
      }
    });

    customizePost(api, container);

    api.addTopicAdminMenuButton((topic) => {
      const canManageTopic = api.getCurrentUser()?.canManageTopic;
      if (canManageTopic) {
        return {
          className: "topic-admin-salesforce-case",
          icon: "briefcase",
          label: topic.salesforce_case
            ? "topic.actions.sync_salesforce_case"
            : "topic.actions.create_salesforce_case",
          action: async () => {
            topic.get("postStream.posts").find((p) => p.post_number === 1);

            topic.salesforce_case_loading = true;

            try {
              const data = await ajax(`/salesforce/cases/sync`, {
                type: "POST",
                data: { topic_id: topic.id },
              });
              topic.salesforce_case = data["case"];
            } catch (error) {
              popupAjaxError(error);
            } finally {
              topic.salesforce_case_loading = false;
            }
          },
        };
      }
    });
  }
}

function customizePost(api) {
  api.modifyClass(
    "model:topic",
    (Superclass) =>
      class extends Superclass {
        @tracked salesforce_case_loading;
        @tracked salesforce_case;
      }
  );

  api.renderAfterWrapperOutlet("post-content-cooked-html", PostSalesforceCase);
}

export default {
  name: "extend-for-salesforce",
  initialize(container) {
    withPluginApi((api) => initializeWithApi(api, container));
  },
};
