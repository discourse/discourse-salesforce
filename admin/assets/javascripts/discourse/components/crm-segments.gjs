import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AdminConfigAreaEmptyList from "discourse/admin/components/admin-config-area-empty-list";
import { eq, or } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import dAgeWithTooltip from "discourse/ui-kit/helpers/d-age-with-tooltip";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import {
  configurationProperties,
  describeConditions,
  propertyLabel,
} from "discourse/plugins/discourse-salesforce/discourse/lib/crm-segments";

const PREFIX = "salesforce.guided_sync.segments";

export default class CrmSegments extends Component {
  @service dialog;

  get segments() {
    return this.args.segments.map((segment) => {
      const properties = configurationProperties(
        this.args.properties,
        segment.configuration_id
      );
      return {
        ...segment,
        conditions: describeConditions(segment, properties),
        missingProperty:
          segment.missing_properties[0] &&
          propertyLabel(segment.missing_properties[0], properties),
        status: segment.connection_changed
          ? "connection_changed"
          : segment.missing_properties.length
            ? "error"
            : !segment.group_id
              ? "unsynced"
              : segment.last_evaluated_at
                ? "synced"
                : "pending",
      };
    });
  }

  @action
  deleteSegment(segment) {
    this.dialog.deleteConfirm({
      title: i18n(`${PREFIX}.delete_title`),
      message: i18n(`${PREFIX}.delete_message`, { name: segment.name }),
      confirmButtonLabel: `${PREFIX}.delete`,
      didConfirm: () => this.args.onDelete(segment),
    });
  }

  <template>
    <div class="crm-segments" ...attributes>
      <DPageSubheader
        @titleLabel={{i18n "salesforce.guided_sync.segments.title"}}
        @descriptionLabel={{i18n "salesforce.guided_sync.segments.description"}}
      />
      {{#if this.segments.length}}
        <table class="d-table crm-segments__table">
          <thead class="d-table__header"><tr>
              <th>{{i18n "salesforce.guided_sync.segments.columns.name"}}</th>
              <th>{{i18n
                  "salesforce.guided_sync.segments.columns.configuration"
                }}</th>
              <th>{{i18n
                  "salesforce.guided_sync.segments.columns.conditions"
                }}</th>
              <th>{{i18n "salesforce.guided_sync.segments.columns.group"}}</th>
              <th>{{i18n
                  "salesforce.guided_sync.segments.columns.members"
                }}</th>
              <th></th>
            </tr></thead>
          <tbody class="d-table__body">
            {{#each this.segments key="id" as |segment|}}
              <tr class="d-table__row" data-test-segment={{segment.id}}>
                <td class="d-table__cell --overview">
                  <strong>{{segment.name}}</strong>
                  <div
                    class="crm-segments__status
                      {{if
                        (or
                          (eq segment.status 'error')
                          (eq segment.status 'connection_changed')
                        )
                        '--error'
                      }}"
                    data-test-segment-status={{segment.status}}
                  >
                    {{#if (eq segment.status "connection_changed")}}
                      {{dIcon "triangle-exclamation"}}
                      {{i18n "salesforce.guided_sync.connection_changed"}}
                    {{else if (eq segment.status "error")}}
                      {{dIcon "triangle-exclamation"}}
                      {{i18n
                        "salesforce.guided_sync.segments.errors.property_not_pulled"
                        property=segment.missingProperty
                      }}
                    {{else if (eq segment.status "synced")}}
                      {{i18n "salesforce.guided_sync.segments.status_synced"}}
                      <span class="crm-segments__age">{{dAgeWithTooltip
                          segment.last_evaluated_at
                        }}</span>
                    {{else if (eq segment.status "pending")}}
                      {{i18n "salesforce.guided_sync.segments.status_pending"}}
                    {{else}}
                      {{i18n "salesforce.guided_sync.segments.status_unsynced"}}
                    {{/if}}
                  </div>
                </td>
                <td
                  class="d-table__cell --detail"
                  data-test-segment-configuration
                ><div class="d-table__mobile-label">{{i18n
                      "salesforce.guided_sync.segments.columns.configuration"
                    }}</div>{{segment.configuration_name}}</td>
                <td class="d-table__cell --detail"><div
                    class="d-table__mobile-label"
                  >{{i18n
                      "salesforce.guided_sync.segments.columns.conditions"
                    }}</div>{{segment.conditions}}</td>
                <td class="d-table__cell --detail"><div
                    class="d-table__mobile-label"
                  >{{i18n
                      "salesforce.guided_sync.segments.columns.group"
                    }}</div>{{#if
                    segment.group_name
                  }}{{segment.group_name}}{{else}}<span
                      class="crm-segments__muted"
                    >{{i18n
                        "salesforce.guided_sync.segments.no_group"
                      }}</span>{{/if}}</td>
                <td class="d-table__cell --detail"><div
                    class="d-table__mobile-label"
                  >{{i18n
                      "salesforce.guided_sync.segments.columns.members"
                    }}</div><span
                    data-test-segment-members
                  >{{segment.member_count}}</span></td>
                <td class="d-table__cell --controls">
                  <div class="d-table__cell-actions">
                    <DButton
                      class="btn-default btn-small"
                      data-test-configure-segment={{segment.id}}
                      @action={{fn @onEdit segment}}
                      @label="salesforce.guided_sync.configure"
                    />
                    <DButton
                      class="btn-danger btn-small"
                      data-test-delete-segment={{segment.id}}
                      @action={{fn this.deleteSegment segment}}
                      @icon="trash-can"
                      @label="salesforce.guided_sync.segments.delete"
                    />
                  </div>
                </td>
              </tr>
            {{/each}}
          </tbody>
        </table>
      {{else}}
        <AdminConfigAreaEmptyList
          @ctaAction={{@onAdd}}
          @ctaLabel={{if @onAdd "salesforce.guided_sync.segments.add"}}
          @emptyLabel={{if
            @onAdd
            "salesforce.guided_sync.segments.empty"
            "salesforce.guided_sync.segments.requires_pull"
          }}
        />
      {{/if}}
    </div>
  </template>
}
