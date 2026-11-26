import { array } from "@ember/helper";
import CrmSyncConfigurations from "discourse/plugins/discourse-salesforce/discourse/components/crm-sync-configurations";

export default <template>
  {{#each (array @model) as |model|}}
    <CrmSyncConfigurations
      @groups={{model.groups}}
      @segmentConfigurations={{model.segmentConfigurations}}
      @segmentGroups={{model.segmentGroups}}
      @segmentProperties={{model.segmentProperties}}
      @segments={{model.segments}}
      @targets={{model.targets}}
      @onClose={{@controller.clearConfiguration}}
      @onSelect={{@controller.selectConfiguration}}
      @providers={{model.providers}}
      @records={{model.configurations}}
      @selectedId={{model.selectedId}}
    />
  {{/each}}
</template>
