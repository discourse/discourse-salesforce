export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",

  map() {
    this.route("salesforce-configurations", { path: "configurations" });
    this.route("salesforce-guided-sync", { path: "guided-sync" });
  },
};
