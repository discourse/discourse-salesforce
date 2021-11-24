import { withPluginApi } from "discourse/lib/plugin-api";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import I18n from "I18n";
import { h } from "virtual-dom";

function createObject(type, context) {
  ajax(`/salesforce/${type}s/create`, {
    type: "POST",
    data: { type, post_id: context.attrs.id },
  })
    .then(() => {
      context.appEvents.trigger("post-stream:refresh", {
        id: context.attrs.id,
      });
    })
    .catch(popupAjaxError);
}

function createLead() {
  createObject("lead", this);
}

function createContact() {
  createObject("contact", this);
}

function createCase(context) {
  createObject("case", context);
}

function initializeWithApi(api) {
  const currentUser = api.getCurrentUser();
  const isStaff = currentUser && currentUser.staff;

  if (isStaff) {
    const salesforce_url = Discourse.SiteSettings.salesforce_instance_url;

    api.addPostMenuButton("salesforce", (attrs) => {
      return {
        id: "salesforce",
        action: "openSalesforceMenu",
        icon: "fab-salesforce",
        title: "salesforce.menu.title",
      };
    });

    api.decorateWidget("post-menu:after", (dec) => {
      if (dec.state.salesforceMenuVisible) {
        return dec.attach("post-salesforce-menu");
      }
    });

    api.attachWidgetAction("post-menu", "openSalesforceMenu", function () {
      this.state.salesforceMenuVisible = true;
    });

    api.attachWidgetAction("post-menu", "closeSalesforceMenu", function () {
      this.state.salesforceMenuVisible = false;
    });

    api.attachWidgetAction("post-menu", "createCase", function () {
      createCase(this);
      this.state.salesforceMenuVisible = false;
    });

    api.createWidget("post-salesforce-menu", {
      tagName: "div.post-admin-menu.post-salesforce-menu.popup-menu",

      html() {
        const contents = [];
        const buttons = [
          {
            icon: "ticket-alt",
            label: "salesforce.case.create",
            action: "createCase",
          },
          {
            icon: "user-tag",
            label: "salesforce.lead.create",
            action: "createLead",
          },
        ];

        buttons.map((b) =>
          contents.push(this.attach("post-salesforce-menu-button", b))
        );
        return h("ul", contents);
      },

      clickOutside() {
        this.sendWidgetAction("closeSalesforceMenu");
      },
    });

    api.createWidget("post-salesforce-menu-button", {
      tagName: "li",

      html(attrs) {
        return this.attach("button", {
          className: attrs.className,
          action: attrs.action,
          url: attrs.url,
          icon: attrs.icon,
          label: attrs.label,
          secondaryAction: attrs.secondaryAction,
        });
      },
    });

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
