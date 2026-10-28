export const USER_SYNC_SOURCES = [
  { id: "first", type: "text" },
  { id: "last", type: "text" },
  { id: "profile", type: "text" },
  { id: "bio", type: "text" },
  { id: "website", type: "text" },
  { id: "company", type: "text" },
  { id: "posts", type: "number", group: "activity" },
  { id: "posts30", type: "number", group: "activity" },
  { id: "read_time", type: "number", group: "activity" },
  { id: "posts_read", type: "number", group: "activity" },
  { id: "topics_entered", type: "number", group: "activity" },
  { id: "likes_given", type: "number", group: "activity" },
  { id: "likes_received", type: "number", group: "activity" },
  { id: "days_visited", type: "number", group: "activity" },
  { id: "trust", type: "number" },
  { id: "groups", type: "text" },
  { id: "seen", type: "date" },
  { id: "static", type: "text" },
];

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

export function normalizeConfiguration(configuration) {
  const normalized = structuredClone(configuration);
  normalized.groups = normalized.groups?.length
    ? normalized.groups
    : normalized.group
      ? [normalized.group]
      : [];
  delete normalized.group;
  delete normalized.onJoin;
  delete normalized.onChange;
  delete normalized.previewUser;
  normalized.mappings = normalized.mappings.map((mapping) =>
    mapping.source === "source"
      ? { ...mapping, source: "static", value: "Community" }
      : mapping
  );
  return normalized;
}

export function mappingError(
  configuration,
  fields,
  sources = USER_SYNC_SOURCES
) {
  for (const mapping of configuration.mappings) {
    if (!mapping.source || !mapping.destination) {
      return "incomplete";
    }
    if (
      mapping.source === "static" &&
      (typeof mapping.value !== "string" ||
        !mapping.value.trim() ||
        mapping.value.length > 1000)
    ) {
      return "static_value";
    }
    const source = sources.find((item) => item.id === mapping.source);
    if (!source) {
      return "source_unavailable";
    }
    const field = fields.find((item) => item.id === mapping.destination);
    if (!field) {
      return "unavailable";
    }
    if (source?.type !== field?.type) {
      return "incompatible";
    }
  }
  if (
    !configuration.mappings.some(
      (mapping) => mapping.destination === "LastName"
    )
  ) {
    return "last_name";
  }
  if (
    configuration.object === "Lead" &&
    !configuration.mappings.some((mapping) => mapping.destination === "Company")
  ) {
    return "company";
  }
}

export function updateMapping(configuration, index, property, value) {
  return configuration.mappings.map((mapping, mappingIndex) => {
    if (mappingIndex === index) {
      return { ...mapping, [property]: value, moved: false };
    }
    if (property === "destination" && value && mapping.destination === value) {
      return { ...mapping, destination: "", moved: true };
    }
    return mapping;
  });
}
