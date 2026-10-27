import { array } from "@ember/helper";
import SalesforceSyncConfigurations from "discourse/plugins/discourse-salesforce/discourse/components/salesforce-sync-configurations";

export default <template>
  {{#each (array @model) as |model|}}
    <SalesforceSyncConfigurations
      @credentialsConfigured={{model.credentials_configured}}
      @groups={{model.groups}}
      @onClose={{@controller.clearConfiguration}}
      @onSelect={{@controller.selectConfiguration}}
      @records={{model.configurations}}
      @selectedId={{model.selectedId}}
    />
  {{/each}}
</template>
