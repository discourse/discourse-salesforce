export const DEMO_SUPPORT_CATEGORIES = [
  { id: "support", labelKey: "support" },
  { id: "product-help", labelKey: "product_help" },
  { id: "enterprise-support", labelKey: "enterprise_support" },
];

export const DEMO_CASE_FIELDS = [
  { id: "Subject", type: "text" },
  { id: "Description", type: "text" },
  { id: "Community_Tags__c", type: "text" },
  { id: "Product_Version__c", type: "text" },
  { id: "files", type: "files" },
];

export function createCaseDemoConfiguration() {
  return {
    kind: "posts",
    object: "Case",
    category: "support",
    environment: "sandbox",
    schedule: "manual",
    onCreate: true,
    onEdit: true,
    outboundReplies: true,
    inboundReplies: true,
    backfill: false,
    mappings: [
      { id: 1, source: "title", destination: "Subject", policy: "overwrite" },
      {
        id: 2,
        source: "description",
        destination: "Description",
        policy: "overwrite",
      },
      {
        id: 3,
        source: "tags",
        destination: "Community_Tags__c",
        policy: "overwrite",
      },
      {
        id: 4,
        source: "version",
        destination: "Product_Version__c",
        policy: "overwrite",
      },
      {
        id: 5,
        source: "attachments",
        destination: "files",
        policy: "overwrite",
      },
    ],
  };
}
