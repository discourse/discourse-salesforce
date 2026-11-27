function companyMapping(id) {
  return {
    id,
    source: "static",
    value: "Unknown",
    destination: "Company",
    policy: "keep",
  };
}

function contactMappings() {
  return [
    { id: 1, source: "first", destination: "FirstName", policy: "keep" },
    { id: 2, source: "last", destination: "LastName", policy: "keep" },
    { id: 3, source: "profile", destination: "Description", policy: "keep" },
  ];
}

export default {
  enabledSetting: "salesforce_enabled",
  name: "Salesforce",
  emailField: "Email",
  metadataUrl: "/salesforce/admin/guided-sync/fields.json",
  targets: {
    Lead: {
      translationKey: "Lead",
      requiredFields: ["LastName", "Company"],
      createMappings: () => [...contactMappings(), companyMapping(6)],
      adaptMappings: (mappings, nextId) =>
        mappings.some((mapping) => mapping.destination === "Company")
          ? mappings
          : [...mappings, companyMapping(nextId)],
    },
    Contact: {
      translationKey: "Contact",
      requiredFields: ["LastName"],
      createMappings: contactMappings,
      adaptMappings: (mappings) =>
        mappings.filter((mapping) => mapping.destination !== "Company"),
    },
  },
  pull: {
    metadataUrl: "/salesforce/admin/guided-sync/fields.json",
    fields: (result) => result.fields,
    objects: {
      Lead: {
        translationKey: "salesforce_lead",
        createMappings: () => [
          { source: "Name", destination: "name", policy: "keep" },
          { source: "Website", destination: "website", policy: "keep" },
        ],
      },
      Contact: {
        translationKey: "salesforce_contact",
        createMappings: () => [
          { source: "Name", destination: "name", policy: "keep" },
        ],
      },
    },
  },
};
