// Mirrors Hubspot::InboundUsersFlow::FULL_NAME.
const FULL_NAME = "firstname+lastname";

export default {
  enabledSetting: "hubspot_enabled",
  name: "HubSpot",
  emailField: "email",
  metadataUrl: "/salesforce/admin/hubspot/properties.json",
  targets: {
    contact: {
      translationKey: "Contact",
      requiredFields: [],
      createMappings: () => [
        { id: 1, source: "first", destination: "firstname", policy: "keep" },
        { id: 2, source: "last", destination: "lastname", policy: "keep" },
      ],
    },
  },
  pull: {
    metadataUrl: "/salesforce/admin/hubspot/properties.json",
    fields: (result) => result.properties,
    objects: {
      contact: {
        translationKey: "hubspot_contact",
        createMappings: () => [
          { source: FULL_NAME, destination: "name", policy: "keep" },
          { source: "website", destination: "website", policy: "keep" },
        ],
      },
      company: {
        translationKey: "hubspot_company",
        kind: "companies",
        storeOnly: true,
        description: "salesforce.guided_sync.hubspot.companies_description",
        createMappings: () => [{ source: "name" }, { source: "domain" }],
      },
    },
  },
};
