import { i18n } from "discourse-i18n";

export default <template>
  <div class="salesforce-delete-sync-confirmation" ...attributes>
    <p>{{i18n "salesforce.guided_sync.delete_message" name=@model.name}}</p>
    {{#if @model.workflows.length}}
      <ul>{{#each @model.workflows key="id" as |workflow|}}<li
          >{{workflow.name}}</li>{{/each}}</ul>
    {{/if}}
    <p>{{i18n "salesforce.guided_sync.delete_scope"}}</p>
  </div>
</template>
