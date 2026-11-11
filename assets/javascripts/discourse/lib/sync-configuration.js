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

export const OTHER_CUSTOM_FIELD_SOURCE = {
  id: "custom_field",
  type: "text",
  group: "custom",
};

const LISTED_CUSTOM_FIELD_PREFIX = "custom_field:";

export function listedCustomFieldOption(name) {
  return `${LISTED_CUSTOM_FIELD_PREFIX}${name}`;
}

export function sourceOption(mapping, customFieldNames) {
  return mapping.source === "custom_field" &&
    !mapping.other &&
    customFieldNames.includes(mapping.value)
    ? listedCustomFieldOption(mapping.value)
    : mapping.source;
}

export function valueInputFor(mapping, customFieldNames) {
  return sourceOption(mapping, customFieldNames) === mapping.source
    ? SOURCE_VALUE_INPUTS[mapping.source]
    : undefined;
}

export const SOURCE_VALUE_INPUTS = {
  static: { id: "static_value", maxLength: 1000 },
  custom_field: {
    id: "custom_field_name",
    maxLength: 256,
    trimmed: true,
    description: "custom_field_description",
  },
};

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

export function updateMapping(
  configuration,
  index,
  property,
  value,
  customFieldNames = []
) {
  return configuration.mappings.map((mapping, mappingIndex) => {
    if (mappingIndex === index) {
      const changed = { ...mapping, [property]: value, moved: false };
      if (property === "source") {
        applySource(changed, mapping, value, customFieldNames);
      }
      return changed;
    }
    if (property === "destination" && value && mapping.destination === value) {
      return { ...mapping, destination: "", moved: true };
    }
    return mapping;
  });
}

function applySource(changed, previous, option, customFieldNames) {
  delete changed.other;
  if (option.startsWith(LISTED_CUSTOM_FIELD_PREFIX)) {
    changed.source = "custom_field";
    changed.value = option.slice(LISTED_CUSTOM_FIELD_PREFIX.length);
    return;
  }
  if (option === "custom_field") {
    changed.other = true;
  }
  if (option !== sourceOption(previous, customFieldNames)) {
    delete changed.value;
  }
}
