import { eq } from "discourse/truth-helpers";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

export default <template>
  <div class="salesforce-guided-sync__connection" ...attributes>
    {{dIcon "fab-salesforce"}}
    <div>
      <div class="salesforce-guided-sync__connection-heading">
        <h4>{{i18n "salesforce.guided_sync.workspace"}}</h4>
        {{#if @connected}}
          <span
            class="salesforce-guided-sync__status"
            data-test-connection-status
          >
            {{dIcon "check"}}
            {{i18n "salesforce.guided_sync.connected"}}
          </span>
        {{/if}}
      </div>
      <p>{{#if @environment}}{{i18n
            (if
              (eq @environment "production")
              "salesforce.guided_sync.production"
              "salesforce.guided_sync.sandbox"
            )
          }}
          ·
          {{i18n "salesforce.guided_sync.shared_connection"}}{{else}}{{i18n
            "salesforce.guided_sync.sample_workspace"
          }}{{/if}}</p>
    </div>
  </div>
</template>
