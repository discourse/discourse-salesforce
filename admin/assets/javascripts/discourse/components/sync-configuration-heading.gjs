import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import Form from "discourse/components/form";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class SyncConfigurationHeading extends Component {
  @tracked formData;

  @action
  edit() {
    this.formData = { name: this.args.title };
  }

  @action
  cancel() {
    this.formData = null;
  }

  @action
  handleKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.cancel();
    }
  }

  @action
  apply({ name }) {
    const value = name.trim();
    if (!value) {
      return;
    }
    this.args.onApply(value);
    this.formData = null;
  }

  @action
  allowNavigation() {
    return false;
  }

  <template>
    <div class="sync-configuration-heading" ...attributes>
      {{#if this.formData}}
        <Form
          class="sync-configuration-heading__form"
          @data={{this.formData}}
          @onDirtyCheck={{this.allowNavigation}}
          @onSubmit={{this.apply}}
          as |form|
        >
          <form.Field
            @format="full"
            @name="name"
            @showTitle={{false}}
            @title={{i18n "salesforce.guided_sync.configuration_name"}}
            @type="input"
            @validation="required"
            as |field|
          >
            <field.Control
              @autofocus={{true}}
              @maxlength={{60}}
              {{on "keydown" this.handleKeydown}}
            />
          </form.Field>
          <div class="sync-configuration-heading__actions">
            <DButton
              class="btn-primary"
              type="submit"
              @icon="check"
              @title="salesforce.guided_sync.apply_name"
            />
            <DButton
              class="btn-transparent"
              @action={{this.cancel}}
              @icon="xmark"
              @title="cancel"
            />
          </div>
        </Form>
      {{else}}
        <DPageSubheader @titleLabel={{@title}} />
        {{#if @editable}}
          <DButton
            class="btn-transparent"
            data-test-edit-name
            @action={{this.edit}}
            @icon="pencil"
            @title="salesforce.guided_sync.edit_name"
          />
        {{/if}}
      {{/if}}
    </div>
  </template>
}
