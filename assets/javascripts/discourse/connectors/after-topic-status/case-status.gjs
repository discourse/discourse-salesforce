import icon from "discourse/helpers/d-icon";
import { i18n } from "discourse-i18n";

const CaseStatus = <template>
  {{~#if @outletArgs.topic.has_salesforce_case~}}
    <span title={{i18n "topic_statuses.case.help"}} class="topic-status">
      {{~icon "briefcase"~}}
    </span>
  {{~/if~}}
</template>;

export default CaseStatus;
