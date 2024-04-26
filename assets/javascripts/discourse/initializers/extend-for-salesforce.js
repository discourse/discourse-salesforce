import { spinnerHTML } from "discourse/helpers/loading-spinner";
import TopicStatusIcons from "discourse/helpers/topic-status-icons";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { withPluginApi } from "discourse/lib/plugin-api";
import PostCooked from "discourse/widgets/post-cooked";
import { iconHTML } from "discourse-common/lib/icon-library";
import discourseComputed from "discourse-common/utils/decorators";
import I18n from "I18n";

const PLUGIN_ID = "discourse-salesforce";

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

function syncCaseForTopic(context) {
  const topic = context.topic;
  const op = context.topic
    .get("postStream.posts")
    .find((p) => p.post_number === 1);

  topic.set("salesforce_case", spinnerHTML);
  context.appEvents.trigger("post-stream:refresh", {
    id: op.id,
  });

  ajax(`/salesforce/cases/sync`, {
    type: "POST",
    data: { topic_id: topic.id },
  })
    .catch(popupAjaxError)
    .then((data) => {
      topic.set("salesforce_case", data["case"]);
      context.appEvents.trigger("post-stream:refresh", {
        id: op.id,
      });
    });
}

function initializeWithApi(api, container) {
  const currentUser = api.getCurrentUser();
  const isStaff = currentUser?.staff;
  const appEvents = container.lookup("service:app-events");

  if (isStaff) {
    api.modifyClass("raw-view:topic-status", {
      pluginId: PLUGIN_ID,

      @discourseComputed
      statuses() {
        const results = this._super(...arguments);

        if (this.topic.has_salesforce_case) {
          results.push({
            openTag: "span",
            closeTag: "span",
            title: I18n.t("topic_statuses.case.help"),
            icon: "briefcase",
            key: "case",
          });
        }
        return results;
      },
    });

    TopicStatusIcons.addObject(["has_salesforce_case", "briefcase", "case"]);
    const siteSettings = container.lookup("service:site-settings");
    const salesforceUrl = siteSettings.salesforce_instance_url;

    api.addPostAdminMenuButton(() => {
      return {
        icon: "user-plus",
        label: "salesforce.lead.create",
        action: async (post) => {
          await createPerson("lead", post);
          appEvents.trigger("post-stream:refresh", { id: post.id });
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
          appEvents.trigger("post-stream:refresh", { id: post.id });
        },
        className: "create-contact",
      };
    });

    api.addPosterIcon((cfs) => {
      if (cfs.salesforce_lead_id) {
        return {
          icon: "user-plus",
          className: "salesforce-lead",
          title: I18n.t("salesforce.poster_icon.lead.title"),
          url: `${salesforceUrl}/${cfs.salesforce_lead_id}`,
        };
      }
    });

    api.addPosterIcon((cfs) => {
      if (cfs.salesforce_contact_id) {
        return {
          icon: "address-card",
          className: "salesforce-contact",
          title: I18n.t("salesforce.poster_icon.contact.title"),
          url: `${salesforceUrl}/${cfs.salesforce_contact_id}`,
        };
      }
    });

    api.decorateWidget("post-contents:after-cooked", (dec) => {
      if (dec.attrs.post_number === 1) {
        const postModel = dec.getModel();
        if (postModel) {
          const topic = postModel.topic;
          const salesforceCase = topic.salesforce_case;

          if (salesforceCase) {
            let rawHtml = "";

            if (salesforceCase === spinnerHTML) {
              rawHtml = spinnerHTML;
            } else {
              rawHtml = `
                <aside class='quote salesforce-case' data-id="${
                  salesforceCase.id
                }" data-topic="${topic.id}">
                  <div class='title'>
                  ${iconHTML("briefcase", { class: "case" })}
                    Salesforce Case <a href="${salesforceUrl}/${
                salesforceCase.uid
              }">#${
                salesforceCase.number
              }</a> <div class="quote-controls"><\/div>
                  </div>
                  <blockquote>
                    Status: <strong>${salesforceCase.status}</strong>
                  </blockquote>
                </aside>`;
            }

            const cooked = new PostCooked({ cooked: rawHtml }, dec);
            return dec.rawHtml(cooked.init());
          }
        }
      }
    });

    api.addTopicAdminMenuButton((topic) => {
      const canManageTopic = api.getCurrentUser()?.canManageTopic;
      if (canManageTopic) {
        return {
          className: "topic-admin-salesforce-case",
          icon: "briefcase",
          label: topic.get("salesforce_case")
            ? "topic.actions.sync_salesforce_case"
            : "topic.actions.create_salesforce_case",
          action: () => {
            const op = topic
              .get("postStream.posts")
              .find((p) => p.post_number === 1);
            const _appEvents = container.lookup("service:app-events");

            topic.set("salesforce_case", spinnerHTML);
            _appEvents.trigger("post-stream:refresh", {
              id: op.id,
            });

            ajax(`/salesforce/cases/sync`, {
              type: "POST",
              data: { topic_id: topic.id },
            })
              .catch(popupAjaxError)
              .then((data) => {
                topic.set("salesforce_case", data["case"]);
                _appEvents.trigger("post-stream:refresh", {
                  id: op.id,
                });
              });
          },
        };
      }
    });

    api.modifyClass("component:topic-timeline", {
      pluginId: PLUGIN_ID,
      syncCase() {
        return syncCaseForTopic(this);
      },
    });
  }
}

export default {
  name: "extend-for-salesforce",
  initialize(container) {
    withPluginApi("1.1.0", (api) => initializeWithApi(api, container));
  },
};
