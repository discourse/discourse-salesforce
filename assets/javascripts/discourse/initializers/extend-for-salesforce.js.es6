import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import I18n from "I18n";
import TopicStatusIcons from "discourse/helpers/topic-status-icons";
import PostCooked from "discourse/widgets/post-cooked";
import { spinnerHTML } from "discourse/helpers/loading-spinner";
import { iconHTML } from "discourse-common/lib/icon-library";

export const PLUGIN_ID = "discourse-salesforce";

function createPerson(type, context) {
  const post = context.model;
  post.set("flair_url", "loading spinner");
  ajax(`/salesforce/persons/create`, {
    type: "POST",
    data: { type, user_id: post.user_id },
  }).catch(popupAjaxError).then(() => {
    post.set("flair_url", "fab-salesforce");
    context.appEvents.trigger("post-stream:refresh", { id: post.id });
  });
}

function createLead() {
  createPerson("lead", this);
}

function createContact() {
  createPerson("contact", this);
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

function initializeWithApi(api) {
  const currentUser = api.getCurrentUser();
  const isStaff = currentUser && currentUser.staff;

  if (isStaff) {
    api.modifyClass("raw-view:topic-status", {
      // eslint-disable-next-line no-undef
      statuses: Ember.computed(function () {
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
      }),
    });

    TopicStatusIcons.addObject(["has_salesforce_case", "briefcase", "case"]);
    // eslint-disable-next-line no-undef
    const salesforceUrl = Discourse.SiteSettings.salesforce_instance_url;

    api.decorateWidget("post-admin-menu:after", (dec) => {
      return dec.h(
        "ul",
        dec.attach("post-admin-menu-button", {
          icon: "user-plus",
          label: "salesforce.lead.create",
          action: "createLead",
          secondaryAction: "closeAdminMenu",
          className: "create-lead",
        })
      );
    });

    api.decorateWidget("post-admin-menu:after", (dec) => {
      return dec.h(
        "ul",
        dec.attach("post-admin-menu-button", {
          icon: "address-card",
          label: "salesforce.contact.create",
          action: "createContact",
          secondaryAction: "closeAdminMenu",
          className: "create-contact",
        })
      );
    });

    api.attachWidgetAction("post", "createLead", createLead);
    api.attachWidgetAction("post", "createContact", createContact);

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

    api.decorateWidget("topic-admin-menu:adminMenuButtons", (dec) => {
      const topic = dec.attrs.topic;
      const { canManageTopic } = dec.widget.currentUser || {};
      if (!canManageTopic) {
        return;
      }

      dec.widget.addActionButton({
        className: "topic-admin-salesforce-case",
        buttonClass: "popup-menu-btn",
        action: "syncCase",
        icon: "briefcase",
        label: topic.salesforce_case
          ? "actions.sync_salesforce_case"
          : "actions.create_salesforce_case",
      });
    });

    api.modifyClass("component:topic-admin-menu-button", {
      pluginId: PLUGIN_ID,
      syncCase() {
        return syncCaseForTopic(this);
      },
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
  initialize() {
    withPluginApi("1.1.0", initializeWithApi);
  },
};
