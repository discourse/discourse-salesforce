export default {
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
};
