export const DEMO_SOURCES = [
  { id: "first", type: "text" },
  { id: "last", type: "text" },
  { id: "profile", type: "text" },
  { id: "company", type: "text" },
  { id: "posts", type: "number" },
  { id: "posts30", type: "number" },
  { id: "trust", type: "number" },
  { id: "groups", type: "text" },
  { id: "seen", type: "date" },
  { id: "static", type: "text" },
];

export const DEMO_FIELDS = [
  { id: "FirstName", type: "text" },
  { id: "LastName", type: "text" },
  { id: "Description", type: "text" },
  { id: "Company", type: "text" },
  { id: "LeadSource", type: "text" },
  { id: "Posts_Created__c", type: "number" },
  { id: "Posts_30_Days__c", type: "number" },
  { id: "Community_Trust_Level__c", type: "number" },
  { id: "Community_Groups__c", type: "text" },
  { id: "Last_Seen__c", type: "date" },
];

export const DEMO_USERS = [
  {
    id: "alex",
    name: "Alex Morgan",
    username: "alex",
    email: "alex@example.com",
    company: "Northstar",
    posts: 86,
    posts30: 9,
    trust: 2,
    seen: "2026-10-19",
    existing: {
      Email: "alex@example.com",
      FirstName: "Alexander",
      LastName: "Morgan",
      Description: "Interested in the enterprise plan.",
      Company: "Northstar Ltd.",
      LeadSource: "Partner referral",
      Posts_Created__c: 42,
      Posts_30_Days__c: 4,
      Community_Trust_Level__c: 1,
    },
  },
  {
    id: "maya",
    name: "Maya Chen",
    username: "maya",
    email: "maya@example.com",
    company: "Acme",
    posts: 128,
    posts30: 14,
    trust: 3,
    seen: "2026-10-20",
  },
  {
    id: "kai",
    name: "Kai",
    username: "kai",
    email: "kai@example.com",
    company: "Independent",
    posts: 12,
    posts30: 3,
    trust: 1,
    seen: "2026-10-18",
  },
];

export function createDemoConfiguration() {
  return {
    previewUser: "alex",
    group: "",
    object: "Lead",
    schedule: "daily",
    onJoin: true,
    onChange: true,
    backfill: true,
    mappings: [
      { id: 1, source: "first", destination: "FirstName", policy: "keep" },
      { id: 2, source: "last", destination: "LastName", policy: "keep" },
      { id: 3, source: "profile", destination: "Description", policy: "keep" },
      { id: 6, source: "company", destination: "Company", policy: "overwrite" },
    ],
  };
}

export function normalizeConfiguration(configuration) {
  const normalized = structuredClone(configuration);
  normalized.mappings = normalized.mappings.map((mapping) =>
    mapping.source === "source"
      ? { ...mapping, source: "static", value: "Community" }
      : mapping
  );
  return normalized;
}

export function destinationName(field) {
  return field;
}

export function mappingError(configuration, fields = DEMO_FIELDS) {
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
    const source = DEMO_SOURCES.find((item) => item.id === mapping.source);
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

function sourceValue(source, user, configuration) {
  const words = user.name.trim().split(/\s+/);
  return {
    first: words.length > 1 ? words[0] : "",
    last: words.length > 1 ? words.slice(1).join(" ") : words[0],
    profile: `https://community.example.com/u/${user.username}`,
    company: user.company,
    posts: user.posts,
    posts30: user.posts30,
    trust: user.trust,
    groups: configuration.group,
    seen: user.seen,
    source: "Community",
  }[source];
}

export function buildPreview(configuration, userId) {
  const user = DEMO_USERS.find((item) => item.id === userId);
  const mappings = [
    { source: "email", destination: "Email", policy: "keep" },
    ...configuration.mappings.filter(
      (mapping) => mapping.source && mapping.destination
    ),
  ];
  return mappings.map((mapping) => {
    const current = user.existing?.[mapping.destination];
    const incoming =
      mapping.source === "email"
        ? user.email
        : mapping.source === "static"
          ? mapping.value
          : sourceValue(mapping.source, user, configuration);
    const keep =
      mapping.policy === "keep" &&
      current !== undefined &&
      current !== null &&
      current !== "";
    const result = keep ? current : incoming;
    let outcome = user.existing ? "updated" : "set";
    if (mapping.source === "email" && user.existing) {
      outcome = "matched";
    } else if (keep) {
      outcome = "kept";
    } else if (current === incoming) {
      outcome = "unchanged";
    }
    return {
      field: destinationName(mapping.destination, configuration.object),
      current: current ?? "—",
      incoming: incoming === "" ? "—" : incoming,
      result: result === "" ? "—" : result,
      outcome,
    };
  });
}
