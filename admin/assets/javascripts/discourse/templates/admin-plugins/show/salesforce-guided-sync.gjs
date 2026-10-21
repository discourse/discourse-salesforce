import { array } from "@ember/helper";
import SalesforceSyncConfigurations from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-sync-configurations";

export default <template>
  {{#each (array @model) as |model|}}
    <SalesforceSyncConfigurations
      @connection={{model.connection}}
      @onClose={{@controller.clearConfiguration}}
      @records={{model.configurations}}
      @selectedId={{model.selectedId}}
    />
  {{/each}}
</template>
