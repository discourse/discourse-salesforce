import DTooltip from "discourse/float-kit/components/d-tooltip";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

const CrmSegmentBadge = <template>
  <DTooltip
    class="crm-segment-badge"
    @arrow={{false}}
    @identifier="crm-segment-badge"
    @interactive={{true}}
    ...attributes
  >
    <:trigger>
      <span class="crm-segment-badge__chip">
        {{dIcon (if @icon @icon "address-card")}}
        {{@label}}
      </span>
    </:trigger>
    <:content>
      <div class="crm-segment-badge__tooltip">
        {{#each @entries key="id" as |entry|}}
          <div class="crm-segment-badge__row">
            <span class="crm-segment-badge__row-label">{{entry.label}}</span>
            <span class="crm-segment-badge__row-value">
              {{#if entry.value}}
                {{entry.value}}
              {{else}}
                <span class="crm-segment-badge__muted">{{i18n
                    "salesforce.guided_sync.segments.tooltip_no_value"
                  }}</span>
              {{/if}}
            </span>
          </div>
        {{else}}
          <span class="crm-segment-badge__muted">{{i18n
              "salesforce.guided_sync.segments.tooltip_empty"
            }}</span>
        {{/each}}
        {{#if @url}}
          <a
            class="crm-segment-badge__link"
            href={{@url}}
            rel="noopener noreferrer"
            target="_blank"
          >{{i18n "salesforce.guided_sync.segments.tooltip_open_in_crm"}}</a>
        {{else}}
          <span class="crm-segment-badge__link">{{i18n
              "salesforce.guided_sync.segments.tooltip_open_in_crm"
            }}</span>
        {{/if}}
      </div>
    </:content>
  </DTooltip>
</template>;

export default CrmSegmentBadge;
