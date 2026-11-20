import { tracked } from "@glimmer/tracking";
import { later } from "@ember/runloop";
import { i18n } from "discourse-i18n";

const PREFIX = "salesforce.guided_sync.segments";
const DELAY = 150;

export const OPERATORS = [
  { id: "equals", valued: true },
  { id: "not_equals", valued: true },
  { id: "contains", valued: true },
  { id: "not_contains", valued: true },
  { id: "set", valued: false },
  { id: "not_set", valued: false },
];

export const PROPERTIES = [
  pulledProperty("contact", "lifecyclestage", "Lifecycle stage"),
  pulledProperty("contact", "jobtitle", "Job title"),
  pulledProperty("company", "name", "Company name"),
  pulledProperty("company", "plan_tier", "Plan tier"),
  pulledProperty("company", "churned_", "Churned"),
  pulledProperty("company", "industry", "Industry"),
  pulledProperty("company", "numberofemployees", "Number of employees"),
];

const USERS = [
  user("sam", { lifecyclestage: "customer", jobtitle: "Engineer" }, acme()),
  user(
    "alex",
    { lifecyclestage: "customer", jobtitle: "Support lead" },
    acme()
  ),
  user("jo", { lifecyclestage: "customer" }, globex()),
  user("kim", { lifecyclestage: "lead", jobtitle: "Founder" }, initech()),
  user("pat", { lifecyclestage: "customer", jobtitle: "CTO" }, initech()),
  user("lee", { lifecyclestage: "opportunity" }, null),
  user("dana", { lifecyclestage: "customer", jobtitle: "Admin" }, umbrella()),
  user("max", { lifecyclestage: "subscriber" }, null),
  user("robin", { lifecyclestage: "customer", jobtitle: "Analyst" }, globex()),
  user("casey", { lifecyclestage: "customer" }, acme()),
  user(
    "taylor",
    { lifecyclestage: "evangelist", jobtitle: "DevRel" },
    umbrella()
  ),
  user("morgan", { lifecyclestage: "customer", jobtitle: "Buyer" }, initech()),
];

const AUTOMATIC_GROUP_IDS = new Set([0, 1, 2, 3, 4, 5, 10, 11, 12, 13, 14]);
const SEGMENTS = new Map();

const state = new (class {
  @tracked version = 0;
})();

function pulledProperty(object, name, label) {
  return { id: `${object}.${name}`, provider: "HubSpot", object, name, label };
}

function user(username, contact, company) {
  return { username, contact, company };
}

function acme() {
  return {
    name: "Acme Corp",
    plan_tier: "Enterprise",
    churned_: "No",
    industry: "Software",
    numberofemployees: "250",
  };
}

function globex() {
  return {
    name: "Globex",
    plan_tier: "Enterprise plus",
    industry: "Finance",
    numberofemployees: "40",
  };
}

function initech() {
  return {
    name: "Initech",
    plan_tier: "Business",
    churned_: "Yes",
    industry: "Software",
    numberofemployees: "12",
  };
}

function umbrella() {
  return {
    name: "Umbrella",
    plan_tier: "Enterprise",
    churned_: "Yes",
    industry: "Health",
    numberofemployees: "900",
  };
}

function condition(id, property, operator, value = "") {
  return { id, property, operator, value };
}

function hoursAgo(hours) {
  return new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();
}

export function syncableGroups(groups = []) {
  return groups.filter((group) => !AUTOMATIC_GROUP_IDS.has(Number(group.id)));
}

function seed(groups) {
  if (SEGMENTS.size) {
    return;
  }
  const syncable = syncableGroups(groups);
  const groupId = (index, fallback) => syncable[index]?.id ?? fallback;
  [
    {
      id: 1,
      name: "Enterprise customers",
      match: "all",
      conditions: [
        condition(1, "company.plan_tier", "contains", "enterprise"),
        condition(2, "company.churned_", "not_equals", "Yes"),
      ],
      sync_group: true,
      group_id: groupId(0, "enterprise-customers"),
      show_badge: true,
      badge_label: "Enterprise customer",
      badge_properties: [
        "company.name",
        "company.plan_tier",
        "contact.lifecyclestage",
      ],
      evaluated_at: hoursAgo(2),
      error: null,
    },
    {
      id: 2,
      name: "Churn risk",
      match: "all",
      conditions: [
        condition(1, "contact.hs_lead_status", "equals", "AT_RISK"),
        condition(2, "company.churned_", "not_set"),
      ],
      sync_group: true,
      group_id: groupId(1, "churn-risk"),
      show_badge: true,
      badge_label: "",
      badge_properties: ["company.churned_"],
      evaluated_at: hoursAgo(26),
      error: i18n(`${PREFIX}.errors.property_not_pulled`, {
        property: "hs_lead_status",
      }),
    },
    {
      id: 3,
      name: "Trial accounts",
      match: "any",
      conditions: [
        condition(1, "contact.lifecyclestage", "equals", "opportunity"),
        condition(2, "contact.lifecyclestage", "equals", "lead"),
      ],
      sync_group: false,
      group_id: null,
      show_badge: false,
      badge_label: "",
      badge_properties: [],
      evaluated_at: null,
      error: null,
    },
  ].forEach((segment) => SEGMENTS.set(segment.id, segment));
}

function wait(result) {
  return new Promise((resolve) => later(() => resolve(result), DELAY));
}

function nextId() {
  return Math.max(0, ...SEGMENTS.keys()) + 1;
}

function propertyValue(record, propertyId) {
  const [object, name] = propertyId.split(".");
  const value = record[object]?.[name];
  return value === undefined || value === null || value === ""
    ? null
    : String(value);
}

export function conditionMatches(
  record,
  { property: propertyId, operator, value }
) {
  const actual = propertyValue(record, propertyId);
  const expected = (value || "").trim().toLowerCase();
  const current = actual?.toLowerCase();
  switch (operator) {
    case "set":
      return actual !== null;
    case "not_set":
      return actual === null;
    case "equals":
      return current === expected;
    case "not_equals":
      return current !== expected;
    case "contains":
      return actual !== null && current.includes(expected);
    case "not_contains":
      return actual === null || !current.includes(expected);
    default:
      return false;
  }
}

export function segmentMatches(record, segment) {
  const complete = segment.conditions.filter(
    (item) => item.property && item.operator
  );
  if (complete.length === 0) {
    return false;
  }
  const results = complete.map((item) => conditionMatches(record, item));
  return segment.match === "any"
    ? results.some(Boolean)
    : results.every(Boolean);
}

export function unknownProperties(segment) {
  return segment.conditions
    .map((item) => item.property)
    .filter(
      (propertyId) =>
        propertyId && !PROPERTIES.some((item) => item.id === propertyId)
    )
    .map((propertyId) => propertyId.split(".")[1]);
}

export function evaluate(segment) {
  const matches = USERS.filter((record) => segmentMatches(record, segment));
  return {
    count: matches.length,
    total: USERS.length,
    usernames: matches.map((record) => record.username),
  };
}

export function describeConditions(segment) {
  const parts = segment.conditions
    .filter((item) => item.property && item.operator)
    .map((item) => {
      const known = PROPERTIES.find((entry) => entry.id === item.property);
      return i18n(`${PREFIX}.operators.${item.operator}_sentence`, {
        property: known?.label || item.property.split(".")[1],
        value: item.value,
      });
    });
  if (parts.length === 0) {
    return i18n(`${PREFIX}.no_conditions`);
  }
  return parts.join(i18n(`${PREFIX}.join_${segment.match}`));
}

export function createSegment() {
  return {
    name: "",
    match: "all",
    conditions: [condition(1, "", "equals", "")],
    sync_group: true,
    group_id: null,
    show_badge: false,
    badge_label: "",
    badge_properties: [],
    evaluated_at: null,
    error: null,
  };
}

export function tooltipPreview(segment) {
  const sample = USERS.find((record) => segmentMatches(record, segment));
  return (segment.badge_properties || []).map((propertyId) => {
    const known = PROPERTIES.find((item) => item.id === propertyId);
    return {
      id: propertyId,
      label: known?.label || propertyId.split(".")[1],
      value: sample ? propertyValue(sample, propertyId) : null,
    };
  });
}

export function badgeLabel(segment) {
  return segment.badge_label?.trim() || segment.name;
}

export function listSegments(groups = []) {
  seed(groups);
  state.version;
  return [...SEGMENTS.values()].map((segment) => structuredClone(segment));
}

export function findSegment(id, groups = []) {
  seed(groups);
  state.version;
  const segment = SEGMENTS.get(Number(id));
  return segment ? structuredClone(segment) : null;
}

export async function saveSegment(segment) {
  const missing = unknownProperties(segment);
  const saved = {
    ...structuredClone(segment),
    id: segment.id ?? nextId(),
    evaluated_at:
      segment.sync_group || segment.show_badge
        ? new Date().toISOString()
        : null,
    error: missing.length
      ? i18n(`${PREFIX}.errors.property_not_pulled`, { property: missing[0] })
      : null,
  };
  SEGMENTS.set(saved.id, saved);
  state.version++;
  return wait(structuredClone(saved));
}

export async function deleteSegment(id) {
  SEGMENTS.delete(Number(id));
  state.version++;
  return wait(true);
}
