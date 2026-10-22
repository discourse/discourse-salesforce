import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class PostMenuUnlinkSalesforceCase extends Component {
  static hidden = true;
  static showLabel = true;

  static shouldRender({ post }) {
    return !!(
      post.post_number === 1 &&
      post.topic?.salesforce_case &&
      post.topic?.can_unlink_salesforce_case
    );
  }

  @service dialog;
  @service toasts;

  get topic() {
    return this.args.post.topic;
  }

  get case() {
    return this.topic.salesforce_case;
  }

  @action
  async unlinkCase() {
    const caseId = this.case.id;
    const confirmed = await this.dialog.confirm({
      message: i18n("salesforce.case.unlink_confirmation", {
        number: this.case.number,
      }),
      confirmButtonLabel: "salesforce.case.unlink",
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
    <DButton
      class="post-action-menu__unlink-salesforce-case"
      ...attributes
      @action={{this.unlinkCase}}
      @disabled={{this.topic.salesforce_case_loading}}
      @icon="link-slash"
      @label={{if @showLabel "salesforce.case.unlink"}}
      @title="salesforce.case.unlink"
    />
  </template>
}
