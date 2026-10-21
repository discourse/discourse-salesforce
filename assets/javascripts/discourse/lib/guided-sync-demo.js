export const DEMO_GROUPS = [
  { id: "community-members", count: 248 },
  { id: "customers", count: 86 },
  { id: "partners", count: 32 },
];

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
  { id: "source", type: "text" },
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
    environment: "sandbox",
    previewUser: "alex",
    group: "community-members",
    object: "Lead",
    schedule: "daily",
    onJoin: true,
    onChange: true,
    backfill: true,
    mappings: [
      { id: 1, source: "first", destination: "FirstName", policy: "keep" },
      { id: 2, source: "last", destination: "LastName", policy: "keep" },
      { id: 3, source: "profile", destination: "Description", policy: "keep" },
      {
        id: 4,
        source: "posts",
        destination: "Posts_Created__c",
        policy: "overwrite",
      },
      {
        id: 5,
        source: "trust",
        destination: "Community_Trust_Level__c",
        policy: "overwrite",
      },
      { id: 6, source: "company", destination: "Company", policy: "overwrite" },
      { id: 7, source: "source", destination: "LeadSource", policy: "keep" },
    ],
  };
}

export function destinationName(field, object) {
  if (object === "DiscourseContact__c" && !field.endsWith("__c")) {
    return `${field}__c`;
  }
  if (object === "Contact" && field === "Company") {
    return "Company_Name__c";
  }
  return field;
}

export function mappingError(configuration) {
  for (const mapping of configuration.mappings) {
    if (!mapping.source || !mapping.destination) {
      return "incomplete";
    }
    const source = DEMO_SOURCES.find((item) => item.id === mapping.source);
    const field = DEMO_FIELDS.find((item) => item.id === mapping.destination);
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

export function buildWorkflows(configuration) {
  return [
    ...(configuration.onJoin ? [{ id: "join", icon: "user-plus" }] : []),
    ...(configuration.onChange ? [{ id: "change", icon: "user-pen" }] : []),
    ...(configuration.schedule !== "manual"
      ? [{ id: "refresh", icon: "clock" }]
      : []),
    { id: "backfill", icon: "database" },
  ];
}
