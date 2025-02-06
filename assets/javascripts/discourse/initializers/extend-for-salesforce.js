import { spinnerHTML } from "discourse/helpers/loading-spinner";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import discourseComputed from "discourse/lib/decorators";
import { withSilencedDeprecations } from "discourse/lib/deprecated";
import { iconHTML } from "discourse/lib/icon-library";
import { withPluginApi } from "discourse/lib/plugin-api";
import PostCooked from "discourse/widgets/post-cooked";
import { i18n } from "discourse-i18n";

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
  const appEvents = container.lookup("service:app-events");

  if (isStaff) {
    withSilencedDeprecations("discourse.hbr-topic-list-overrides", () => {
      let topicStatusIcons;
      try {
        topicStatusIcons =
          require("discourse/helpers/topic-status-icons").default;
      } catch {}

      topicStatusIcons?.addObject(["has_salesforce_case", "briefcase", "case"]);

      api.modifyClass(
        "raw-view:topic-status",
        (Superclass) =>
          class extends Superclass {
            @discourseComputed("topic.{has_salesforce_case}")
            statuses() {
              const results = super.statuses;

              if (this.topic.has_salesforce_case) {
                results.push({
                  openTag: "span",
                  closeTag: "span",
                  title: i18n("topic_statuses.case.help"),
                  icon: "briefcase",
                  key: "case",
                });
              }

              return results;
            }
          }
      );
    });

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
  }
}

export default {
  name: "extend-for-salesforce",
  initialize(container) {
    withPluginApi("2.0.0", (api) => initializeWithApi(api, container));
  },
};
