import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class PostSalesforceCase extends Component {
  static shouldRender(args) {
    return args.post.post_number === 1;
  }

  @service dialog;
  @service siteSettings;
  @service toasts;

  get topic() {
    return this.args.post.topic;
  }

  get loading() {
    return this.topic.salesforce_case_loading;
  }

  get case() {
    return this.topic.salesforce_case;
  }

  get caseUrl() {
    return `${this.siteSettings.salesforce_instance_url}/${this.case?.uid}`;
  }

  get caseNumber() {
    return `#${this.case?.number}`;
  }

  @action
  async unlinkCase() {
    const caseId = this.case.id;
    const confirmed = await this.dialog.confirm({
      message: i18n("salesforce.case.unlink_confirmation", {
        number: this.case.number,
      }),
      confirmButtonLabel: "salesforce.case.unlink",
      confirmButtonClass: "btn-danger",
    });
    if (!confirmed) {
      return;
    }

    this.topic.salesforce_case_loading = true;
    try {
      await ajax(`/salesforce/cases/${caseId}`, { type: "DELETE" });
      this.topic.salesforce_case = null;
      this.toasts.success({
        data: { message: i18n("salesforce.case.unlink_success") },
      });
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.topic.salesforce_case_loading = false;
    }
  }

  <template>
    <ConditionalLoadingSpinner @condition={{this.loading}}>
      {{#if this.case}}
        <aside
          class="quote salesforce-case"
          data-id={{this.case.id}}
          data-topic={{this.topic.id}}
        >
          <div class="title">
            {{icon "briefcase" class="case"}}
            Salesforce Case
            <a href={{this.caseUrl}}>
              {{this.caseNumber}}
            </a>
          </div>
          <blockquote>
            Status:
            <strong>{{this.case.status}}</strong>
          </blockquote>
          {{#if this.topic.can_unlink_salesforce_case}}
            <DButton
              class="btn-danger salesforce-case__unlink"
              @action={{this.unlinkCase}}
              @disabled={{this.loading}}
              @icon="trash-can"
              @label="salesforce.case.unlink"
            />
          {{/if}}
        </aside>
      {{/if}}
    </ConditionalLoadingSpinner>
  </template>
}
