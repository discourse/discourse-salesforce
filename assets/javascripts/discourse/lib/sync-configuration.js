import { i18n } from "discourse-i18n";

export const USER_SYNC_SOURCES = [
  { id: "first", type: "text" },
  { id: "last", type: "text" },
  { id: "profile", type: "text" },
  { id: "bio", type: "text" },
  { id: "website", type: "text" },
  { id: "posts", type: "number", group: "activity" },
  { id: "posts30", type: "number", group: "activity" },
  { id: "posts_read", type: "number", group: "activity" },
  { id: "posts_read30", type: "number", group: "activity" },
  { id: "likes_given", type: "number", group: "activity" },
  { id: "likes_given30", type: "number", group: "activity" },
  { id: "likes_received", type: "number", group: "activity" },
  { id: "trust", type: "number" },
  { id: "groups", type: "text" },
  { id: "first_seen", type: "date", group: "activity" },
  { id: "seen", type: "date", group: "activity" },
  { id: "static", type: "text", group: "values" },
];

const LISTED_CUSTOM_FIELD_PREFIX = "listed_custom_field:";

const SOURCE_VALUE_INPUTS = {
  static: { id: "static_value", maxLength: 1000 },
  custom_field: {
    id: "custom_field_name",
    maxLength: 256,
    description: "custom_field_description",
  },
};

function isListedCustomField(mapping, names) {
  return (
    mapping.source === "custom_field" &&
    !mapping.other &&
    names.includes(mapping.value)
  );
}

export function customFieldSources(names) {
  return [
    ...names.map((name) => ({
      id: `${LISTED_CUSTOM_FIELD_PREFIX}${name}`,
      label: name,
    })),
    {
      id: "custom_field",
      label: i18n("salesforce.guided_sync.sources.custom_field"),
    },
  ].map((source) => ({ ...source, type: "text", group: "custom" }));
}

export function sourceOption(mapping, names) {
  return isListedCustomField(mapping, names)
    ? `${LISTED_CUSTOM_FIELD_PREFIX}${mapping.value}`
    : mapping.source;
}

export function valueInputFor(mapping, names) {
  return isListedCustomField(mapping, names)
    ? undefined
    : SOURCE_VALUE_INPUTS[mapping.source];
}

export function sourceLabel(mapping, sources) {
  return (
    (mapping.source === "custom_field" && mapping.value) ||
    sources.find((source) => source.id === mapping.source)?.label ||
    mapping.source
  );
}

export function sourceChange(mapping, option, names) {
  const listed = option.startsWith(LISTED_CUSTOM_FIELD_PREFIX);
  return {
    ...mapping,
    source: listed ? "custom_field" : option,
    value: listed
      ? option.slice(LISTED_CUSTOM_FIELD_PREFIX.length)
      : option === sourceOption(mapping, names)
        ? mapping.value
        : undefined,
    other: option === "custom_field" || undefined,
  };
}

export function createCompanyMapping(id) {
  return {
    id,
    source: "static",
    value: "Unknown",
    destination: "Company",
    policy: "keep",
  };
}

export function createSyncConfiguration() {
  return {
    group_ids: [],
    groups: [],
    object: "Lead",
    schedule: "daily",
    backfill: true,
    mappings: [
      { id: 1, source: "first", destination: "FirstName", policy: "keep" },
      { id: 2, source: "last", destination: "LastName", policy: "keep" },
      { id: 3, source: "profile", destination: "Description", policy: "keep" },
      createCompanyMapping(6),
    ],
  };
}

export function updateMapping(configuration, index, property, value, names) {
  return configuration.mappings.map((mapping, mappingIndex) => {
    if (mappingIndex === index) {
      const changed =
        property === "source"
          ? sourceChange(mapping, value, names)
          : { ...mapping, [property]: value };
      return { ...changed, moved: false };
    }
    if (property === "destination" && value && mapping.destination === value) {
      return { ...mapping, destination: "", moved: true };
    }
    return mapping;
  });
}
