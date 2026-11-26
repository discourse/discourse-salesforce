import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

const PREFIX = "salesforce.guided_sync.segments";
const URL = "/salesforce/admin/guided-sync/segments";

export const OPERATORS = [
  { id: "equals", valued: true },
  { id: "not_equals", valued: true },
  { id: "contains", valued: true },
  { id: "not_contains", valued: true },
  { id: "set", valued: false },
  { id: "not_set", valued: false },
];

export function conditionNeedsValue(operatorId) {
  return OPERATORS.find((item) => item.id === operatorId)?.valued ?? true;
}

export function createSegment(configurationId) {
  return {
    configuration_id: configurationId,
    name: "",
    match: "all",
    conditions: [{ id: 1, property: "", operator: "equals", value: "" }],
    sync_group: true,
    group_id: null,
    remove_unmatched: false,
  };
}

export function segmentForm(segment) {
  const match = Object.keys(segment.conditions)[0];
  return {
    id: segment.id,
    configuration_id: segment.configuration_id,
    name: segment.name,
    match,
    conditions: segment.conditions[match].map((condition) => ({
      id: condition.id,
      property: `${condition.object}.${condition.property}`,
      operator: condition.operator,
      value: condition.value || "",
    })),
    sync_group: !!segment.group_id,
    group_id: segment.group_id,
    remove_unmatched: segment.remove_unmatched,
  };
}

export function conditionsPayload(form) {
  return {
    [form.match]: form.conditions
      .filter((condition) => condition.property && condition.operator)
      .map((condition) => {
        const [object, ...property] = condition.property.split(".");
        return {
          id: condition.id,
          object,
          property: property.join("."),
          operator: condition.operator,
          value: conditionNeedsValue(condition.operator) ? condition.value : "",
        };
      }),
  };
}

export function segmentPayload(form) {
  return {
    configuration_id: form.configuration_id,
    name: form.name,
    conditions: conditionsPayload(form),
    group_id: form.sync_group ? form.group_id : null,
    remove_unmatched: form.sync_group && form.remove_unmatched,
  };
}

export function configurationProperties(properties, configurationId) {
  return properties.filter(
    (property) => String(property.configuration_id) === String(configurationId)
  );
}

export function propertyLabel(propertyId, properties) {
  const known = properties.find((item) => item.id === propertyId);
  return known ? known.label : propertyId.split(".").slice(1).join(".");
}

export function describeConditions(segment, properties) {
  const match = Object.keys(segment.conditions)[0];
  const parts = segment.conditions[match].map((condition) =>
    i18n(`${PREFIX}.operators.${condition.operator}_sentence`, {
      property: propertyLabel(
        `${condition.object}.${condition.property}`,
        properties
      ),
      value: condition.value,
    })
  );
  return parts.join(i18n(`${PREFIX}.join_${match}`));
}

export function saveSegment(id, payload) {
  return ajax(`${URL}${id ? `/${id}` : ""}.json`, {
    type: id ? "PUT" : "POST",
    contentType: "application/json",
    data: JSON.stringify(payload),
  });
}

export function deleteSegment(id) {
  return ajax(`${URL}/${id}.json`, { type: "DELETE" });
}

export function previewSegment(configurationId, conditions) {
  return ajax(`${URL}/preview.json`, {
    type: "POST",
    contentType: "application/json",
    data: JSON.stringify({ configuration_id: configurationId, conditions }),
  });
}
