import Component from "@glimmer/component";
import { service } from "@ember/service";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import icon from "discourse/helpers/d-icon";

export default class PostSalesforceCase extends Component {
  static shouldRender(args) {
    return args.post.post_number === 1;
  }

  @service siteSettings;

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
        </aside>
      {{/if}}
    </ConditionalLoadingSpinner>
  </template>
}
