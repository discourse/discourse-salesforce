import { i18n } from "discourse-i18n";
import hubspot from "discourse/plugins/discourse-salesforce/discourse/lib/hubspot/sync-provider";
import salesforce from "discourse/plugins/discourse-salesforce/discourse/lib/salesforce/sync-provider";

const OUTBOUND_PROVIDERS = { salesforce, hubspot };

export function outboundTarget(provider, object) {
  const definition = OUTBOUND_PROVIDERS[provider];
  return { ...definition, ...definition.targets[object] };
}

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

export function targetLabel(provider, object) {
  const definition = OUTBOUND_PROVIDERS[provider];
  const translationKey = definition?.targets[object]?.translationKey;
  if (!translationKey) {
    return `${definition?.name || provider} - ${object}`;
  }
  return i18n(`salesforce.guided_sync.targets.${provider}.${translationKey}`);
}

export function createSyncConfiguration(
  target = { provider: "salesforce", object: "Lead" }
) {
  return {
    direction: "outbound",
    kind: "users",
    group_ids: [],
    groups: [],
    provider: target.provider,
    object: target.object,
    schedule: "daily",
    backfill: true,
    mappings: outboundTarget(target.provider, target.object).createMappings(),
  };
}

export function createHubspotSyncConfiguration() {
  return {
    provider: "hubspot",
    direction: "inbound",
    kind: "users",
    object: "contact",
    schedule: "daily",
    backfill: true,
    mappings: [{ id: 1, source: "lifecyclestage" }],
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
