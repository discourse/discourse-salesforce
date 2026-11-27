import { concat } from "@ember/helper";
import DTooltip from "discourse/float-kit/components/d-tooltip";
import dConcatClass from "discourse/ui-kit/helpers/d-concat-class";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { providerLabel } from "discourse/plugins/discourse-salesforce/discourse/lib/sync-configuration";

const CrmFlair = <template>
  <DTooltip
    class={{dConcatClass "crm-flair" (concat "--" @flair.provider)}}
    data-test-crm-flair
    @arrow={{false}}
    @identifier="crm-flair"
    @interactive={{true}}
    ...attributes
  >
    <:trigger>
      <span class="crm-flair__chip">
        {{dIcon @flair.icon}}
        <span class="crm-flair__text">{{@flair.text}}</span>
      </span>
    </:trigger>
    <:content>
      <div
        class={{dConcatClass
          "crm-flair__tooltip"
          (concat "--" @flair.provider)
        }}
      >
        {{#each @flair.properties as |property|}}
          <div class="crm-flair__row">
            <span class="crm-flair__label">{{property.label}}</span>
            <span class="crm-flair__value">{{property.value}}</span>
          </div>
        {{/each}}
        {{#if @flair.url}}
          <a
            class="crm-flair__link"
            href={{@flair.url}}
            rel="noopener noreferrer"
            target="_blank"
          >
            {{i18n
              "salesforce.crm_flair.open_in"
              provider=(providerLabel @flair.provider)
            }}
            {{dIcon "arrow-right"}}
          </a>
        {{else}}
          <span class="crm-flair__link">
            {{i18n
              "salesforce.crm_flair.open_in"
              provider=(providerLabel @flair.provider)
            }}
            {{dIcon "arrow-right"}}
          </span>
        {{/if}}
      </div>
    </:content>
  </DTooltip>
</template>;

export default CrmFlair;
