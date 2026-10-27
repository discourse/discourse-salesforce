import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { not } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

export default class SalesforceCreateGroupModal extends Component {
  @service site;

  @tracked error;
  @tracked saving = false;

  data = { name: "" };

  @action
  async create({ name }) {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.error = null;
    try {
      const result = await ajax("/admin/groups", {
        type: "POST",
        data: { group: { name: name.trim(), visibility_level: 0 } },
      });
      const group = { ...result.basic_group, user_count: 0, automatic: false };
      if (!this.site.groups.some((existing) => existing.id === group.id)) {
        this.site.groups.push(group);
      }
      this.args.model.onCreated(group);
      this.args.closeModal();
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.saving = false;
    }
  }

  <template>
    <DModal
      class="salesforce-create-group-modal"
      @closeModal={{@closeModal}}
      @dismissable={{not this.saving}}
      @title={{i18n "salesforce.guided_sync.create_group"}}
    >
      <:body>
        <p>{{i18n "salesforce.guided_sync.create_group_help"}}</p>
        {{#if this.error}}
          <div class="alert alert-error" role="alert">{{this.error}}</div>
        {{/if}}
        <Form @data={{this.data}} @onSubmit={{this.create}} as |form|>
          <form.Field
            @disabled={{this.saving}}
            @format="full"
            @name="name"
            @title={{i18n "salesforce.guided_sync.group_name"}}
            @type="input"
            @validation="required"
            as |field|
          >
            <field.Control @autofocus={{true}} />
          </form.Field>
          <form.Actions>
            <form.Submit @label="salesforce.guided_sync.create_group" />
            <DButton
              class="btn-transparent"
              @action={{@closeModal}}
              @disabled={{this.saving}}
              @label="cancel"
            />
          </form.Actions>
        </Form>
      </:body>
    </DModal>
  </template>
}
