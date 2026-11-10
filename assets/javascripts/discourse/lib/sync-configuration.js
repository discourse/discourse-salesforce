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

export function createCompanyMapping(id) {
  return {
    id,
    source: "static",
    value: "Unknown",
    destination: "Company",
    policy: "keep",
  };
}

export function targetLabel(provider, object) {
  return i18n(`salesforce.guided_sync.targets.${provider}.${object}`);
}

export function createSyncConfiguration(
  target = { provider: "salesforce", object: "Lead" }
) {
  return {
    group_ids: [],
    groups: [],
    provider: target.provider,
    object: target.object,
    schedule: "daily",
    backfill: true,
    mappings:
      target.provider === "hubspot"
        ? [
            {
              id: 1,
              source: "first",
              destination: "firstname",
              policy: "keep",
            },
            { id: 2, source: "last", destination: "lastname", policy: "keep" },
          ]
        : [
            {
              id: 1,
              source: "first",
              destination: "FirstName",
              policy: "keep",
            },
            { id: 2, source: "last", destination: "LastName", policy: "keep" },
            {
              id: 3,
              source: "profile",
              destination: "Description",
              policy: "keep",
            },
            ...(target.object === "Lead" ? [createCompanyMapping(6)] : []),
          ],
  };
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
